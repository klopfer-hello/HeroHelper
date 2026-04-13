--[[
    HeroHelper - Comms Module

    Multi-shaman coordination via the addon-message channel. Built on a
    roster-based election: every HeroHelper user in the group is in a
    shared roster, the lowest-priority alive shaman is the elected
    "lust shaman", and ONLY that one shaman's HeroHelper produces
    reminders. Everyone else stays completely silent.

    Lifecycle:

      Group forms / players zone in
        -> each HeroHelper user broadcasts HELLO:<priority>
        -> rosters converge across all clients
      Group reaches the instance's expected size (GetInstanceInfo's
      maxPlayers — 5 for any 5-man dungeon, 10 for Kara/ZA, 25 for
      the larger raids)
        -> live roster is SNAPSHOTTED into a locked roster
        -> the elected winner posts the order to raid/party chat
           ONCE
        -> late joiners after lock are NOT added to the locked
           roster; the order is fixed for the duration of the run
      During the run
        -> only the elected winner's TryFire actually fires
        -> if the elected winner dies, the next-priority alive
           shaman in the locked roster silently takes over (no
           further chat messages)
      Player leaves the instance or the group disbands
        -> lock is dropped, live roster takes over again

    Pre-lock (group not yet full) and outside any instance both fall
    back to the live roster: AmIElectedWinner runs the same election
    against `roster` + alive check every TryFire. Same code path, no
    special "5-man vs raid" mode.

    Protocol (CHAT_MSG_ADDON, prefix "HEROHELPER"):

        HELLO:<priority>
            "I'm a HeroHelper user. My role priority is <priority>.
             My player name is implicit from the addon-message sender."

    Priority numbers:
       1 = Primary    (always casts when alive)
       2 = Secondary  (casts if Primary is dead)
       3 = Backup     (casts if Primary and Secondary are dead)
      99 = Auto       (no explicit role; alphabetical fallback)
]]

local ADDON_NAME, HH = ...

HH.Comms = {}
local C = HH.Comms

local ADDON_PREFIX = "HEROHELPER"

local PRIORITY_AUTO = 99

-- Live roster: HELLO-discovered HeroHelper users currently in the group.
-- Maintained continuously regardless of mode.
local roster = {}                  -- name -> priority

-- Locked roster: snapshot of `roster` taken when the raid hit expected
-- size for the first time. nil while in live mode. When non-nil, the
-- election runs against this fixed snapshot — late joiners are not
-- added, and the order is preserved for the duration of the raid.
local lockedRoster = nil           -- name -> priority OR nil

-- Tracks whether we've already posted the "this is the order" chat
-- message for the current lock. One announcement per lock cycle.
local lockedAnnounced = false

-- Debounce flags so a burst of GROUP_ROSTER_UPDATE events coalesces
-- into one HELLO broadcast and one lock attempt.
local pendingHello       = false
local pendingLockAttempt = false

-- ============================================================================
-- Helpers
-- ============================================================================

local function GetGroupChannel()
    if IsInRaid and IsInRaid() then return "RAID" end
    if (GetNumRaidMembers and GetNumRaidMembers() or 0) > 0 then return "RAID" end
    if IsInGroup and IsInGroup() then return "PARTY" end
    if (GetNumPartyMembers and GetNumPartyMembers() or 0) > 0 then return "PARTY" end
    return nil
end

local function BareName(name)
    if not name then return nil end
    return name:match("^([^-]+)") or name
end

local function NameLessThan(a, b)
    return (a:lower()) < (b:lower())
end

-- Returns true if the named player is currently alive in the group.
-- Scans player + raid + party slots. Returns false on miss so a player
-- who left the group is implicitly excluded from the election.
local function IsPlayerAlive(name)
    if not name then return false end

    local me = BareName(UnitName("player"))
    if name == me then
        return not UnitIsDeadOrGhost("player")
    end

    local raidN = (GetNumRaidMembers and GetNumRaidMembers() or 0)
    if (IsInRaid and IsInRaid()) or raidN > 0 then
        local n = math.max(raidN, (GetNumGroupMembers and GetNumGroupMembers()) or 0)
        for i = 1, n do
            local unit = "raid" .. i
            if UnitExists(unit) and BareName(UnitName(unit)) == name then
                return not UnitIsDeadOrGhost(unit)
            end
        end
    else
        local partyN = (GetNumPartyMembers and GetNumPartyMembers() or 0)
        for i = 1, partyN do
            local unit = "party" .. i
            if UnitExists(unit) and BareName(UnitName(unit)) == name then
                return not UnitIsDeadOrGhost(unit)
            end
        end
    end

    return false
end

local function SendAddonMsg(message, channel)
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        return pcall(C_ChatInfo.SendAddonMessage, ADDON_PREFIX, message, channel)
    end
    if SendAddonMessage then
        return pcall(SendAddonMessage, ADDON_PREFIX, message, channel)
    end
    return false
end

-- Returns the current instance's expected group size from GetInstanceInfo,
-- or nil if we're not in a raid or party (5-man) instance. Used to know
-- when to lock the election. Excludes "pvp" and "arena" so the lock /
-- chat announcement doesn't fire in battlegrounds.
local function GetExpectedGroupSize()
    if not GetInstanceInfo then return nil end
    local _, instanceType, _, _, maxPlayers = GetInstanceInfo()
    if instanceType ~= "raid" and instanceType ~= "party" then return nil end
    if not maxPlayers or maxPlayers <= 0 then return nil end
    return maxPlayers
end

-- Returns the current actual group size.
local function GetCurrentGroupSize()
    local n = (GetNumRaidMembers and GetNumRaidMembers() or 0)
    if n == 0 and IsInRaid and IsInRaid() then
        n = (GetNumGroupMembers and GetNumGroupMembers() or 0)
    end
    if n == 0 then
        n = (GetNumPartyMembers and GetNumPartyMembers() or 0)
        if n > 0 then n = n + 1 end -- party count excludes self
    end
    return n
end

-- ============================================================================
-- Roster maintenance
-- ============================================================================

-- Removes live-roster entries for players no longer in the group. The
-- locked roster is intentionally NOT pruned — once locked, the order
-- stands for the duration of the raid.
local function PruneLiveRoster()
    local me = BareName(UnitName("player"))
    local inGroup = {}
    if me then inGroup[me] = true end

    local raidN = (GetNumRaidMembers and GetNumRaidMembers() or 0)
    if (IsInRaid and IsInRaid()) or raidN > 0 then
        local n = math.max(raidN, (GetNumGroupMembers and GetNumGroupMembers()) or 0)
        for i = 1, n do
            local unit = "raid" .. i
            if UnitExists(unit) then
                local n2 = BareName(UnitName(unit))
                if n2 then inGroup[n2] = true end
            end
        end
    else
        local partyN = (GetNumPartyMembers and GetNumPartyMembers() or 0)
        for i = 1, partyN do
            local unit = "party" .. i
            if UnitExists(unit) then
                local n2 = BareName(UnitName(unit))
                if n2 then inGroup[n2] = true end
            end
        end
    end

    for name in pairs(roster) do
        if not inGroup[name] then roster[name] = nil end
    end
end

-- Returns the roster currently used for elections: locked snapshot if
-- one exists, otherwise the live roster.
local function GetActiveRoster()
    return lockedRoster or roster
end

-- Picks the elected winner from the given roster, filtered by alive
-- status. Lowest priority wins; ties broken alphabetically. Returns
-- the bidder table { name, priority } or nil if everyone is dead.
local function ElectFrom(srcRoster)
    local chosen = nil
    for name, priority in pairs(srcRoster) do
        if IsPlayerAlive(name) then
            if not chosen
               or priority < chosen.priority
               or (priority == chosen.priority and NameLessThan(name, chosen.name)) then
                chosen = { name = name, priority = priority }
            end
        end
    end
    return chosen
end

-- Returns a roster sorted by priority (then alphabetical) — the order
-- in which ElectFrom walks. Used by the chat announcement.
local function SortedRoster(srcRoster)
    local sorted = {}
    for name, priority in pairs(srcRoster) do
        sorted[#sorted + 1] = { name = name, priority = priority }
    end
    table.sort(sorted, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        return NameLessThan(a.name, b.name)
    end)
    return sorted
end

-- ============================================================================
-- Public API
-- ============================================================================

-- Returns true if THIS player should fire reminders. Used by Triggers.lua
-- to decide whether to suppress its TryFire.
function C:AmIElectedWinner()
    if not (HH.db and HH.db.settings and HH.db.settings.coordinateShamans) then
        return true
    end
    if not GetGroupChannel() then
        return true -- solo
    end

    local me = BareName(UnitName("player"))
    if not me then return true end

    local active = GetActiveRoster()

    -- Empty roster (we're alone with no other HH users discovered yet)
    -- means we trivially win. We're always in our own live roster (added
    -- in BroadcastHello), so this only triggers in degenerate cases.
    local count = 0
    for _ in pairs(active) do count = count + 1 end
    if count == 0 then return true end

    local winner = ElectFrom(active)
    if not winner then
        -- Everyone alive in the active roster is gone. Fall through and
        -- fire as a last resort — IsReady's own checks will block it if
        -- the player is dead too.
        return true
    end
    return winner.name == me
end

-- Returns the locked roster (or live roster if not locked) sorted by
-- priority, for the /hh roster diagnostic command.
function C:GetActiveRosterSorted()
    return SortedRoster(GetActiveRoster())
end

function C:GetElectedWinner()
    local w = ElectFrom(GetActiveRoster())
    return w and w.name or nil
end

function C:IsLocked()
    return lockedRoster ~= nil
end

-- ============================================================================
-- Chat announcement
-- ============================================================================

-- Posts the resolved Heroism order to raid/party chat using the active
-- roster. Called exactly once per raid lock cycle, by the elected winner.
local function PostOrderToChat()
    local sorted = SortedRoster(GetActiveRoster())
    if #sorted == 0 then return end

    local channel = GetGroupChannel()
    if not channel then return end

    local spell = (HH.State and HH.State.spellName) or "Heroism"
    local chosen = sorted[1].name

    local msg
    if #sorted == 1 then
        msg = ("HeroHelper: %s will %s."):format(chosen, spell)
    else
        local names = {}
        for _, s in ipairs(sorted) do names[#names + 1] = s.name end
        msg = ("HeroHelper: %s will %s. Order: %s"):format(
            chosen, spell, table.concat(names, " > "))
    end

    if SendChatMessage then
        pcall(SendChatMessage, msg, channel)
    end
end

-- ============================================================================
-- Lock / unlock
-- ============================================================================

local function ShouldLock()
    if lockedRoster then return false end
    local expected = GetExpectedGroupSize()
    if not expected then return false end
    return GetCurrentGroupSize() >= expected
end

local function MaybeLock()
    if not ShouldLock() then return end

    -- Snapshot the live roster.
    lockedRoster = {}
    local count = 0
    for name, p in pairs(roster) do
        lockedRoster[name] = p
        count = count + 1
    end
    lockedAnnounced = false

    HH:Debug(("Coordinate: election LOCKED with %d HeroHelper user(s)"):format(count))

    -- Run election against the locked snapshot and announce ONCE.
    if HH.db and HH.db.settings and HH.db.settings.announceCoordination then
        local me = BareName(UnitName("player"))
        local winner = ElectFrom(lockedRoster)
        if winner and winner.name == me and not lockedAnnounced then
            lockedAnnounced = true
            PostOrderToChat()
        elseif winner then
            -- Mark as announced even if we're not the announcer, so
            -- subsequent re-checks don't try to announce again from
            -- this client.
            lockedAnnounced = true
        end
    end
end

local function Unlock()
    if not lockedRoster then return end
    lockedRoster = nil
    lockedAnnounced = false
    HH:Debug("Coordinate: election UNLOCKED")
end

-- Called on group / zone changes. Decides whether to keep / drop / set
-- the locked snapshot based on whether we're still in a raid or party
-- instance with a known expected size.
local function ReconcileLockState()
    local expected = GetExpectedGroupSize()
    if not expected then
        -- No longer in a raid/party instance — drop any existing lock.
        Unlock()
        return
    end
    -- We're in an instance; if not yet locked, try to lock now.
    if not lockedRoster then
        MaybeLock()
    end
end

-- ============================================================================
-- HELLO broadcast
-- ============================================================================

local function BroadcastHello()
    if not HH.State.isShaman then return end

    local channel = GetGroupChannel()
    if not channel then return end

    local me = BareName(UnitName("player"))
    if not me then return end

    local p = (HH.db and HH.db.settings and HH.db.settings.shamanPriority) or PRIORITY_AUTO

    -- Self always lives in the live roster (the message we send won't
    -- loop back to us via CHAT_MSG_ADDON, so we add ourselves directly).
    roster[me] = p

    SendAddonMsg("HELLO:" .. tostring(p), channel)
    HH:Debug(("Coordinate: HELLO broadcast on %s (priority=%d)"):format(channel, p))
end

local function ScheduleHello()
    if pendingHello then return end
    pendingHello = true
    C_Timer.After(0.5, function()
        pendingHello = false
        BroadcastHello()
    end)
end

-- Schedules a lock attempt with debounce so a flurry of GROUP_ROSTER_UPDATE
-- events at raid form-up coalesce into a single lock decision.
local function ScheduleLockAttempt()
    if pendingLockAttempt then return end
    pendingLockAttempt = true
    C_Timer.After(2, function()
        pendingLockAttempt = false
        ReconcileLockState()
    end)
end

local function HandleHello(senderName, priority)
    local me = BareName(UnitName("player"))
    if not me or senderName == me then return end

    local prev = roster[senderName]
    roster[senderName] = priority
    if prev ~= priority then
        HH:Debug(("Coordinate: HELLO from %s (priority=%d)"):format(senderName, priority))
    end

    -- A late HELLO during raid form-up may push the locked decision
    -- forward (we now know about another HH user). The lock attempt is
    -- debounced and idempotent.
    ScheduleLockAttempt()
end

-- ============================================================================
-- Lifecycle
-- ============================================================================

function C:Initialize()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        pcall(C_ChatInfo.RegisterAddonMessagePrefix, ADDON_PREFIX)
    elseif RegisterAddonMessagePrefix then
        pcall(RegisterAddonMessagePrefix, ADDON_PREFIX)
    end

    HH.Events:On("CHAT_MSG_ADDON", function(prefix, message, _channel, sender)
        if prefix ~= ADDON_PREFIX or not message then return end

        local senderName = BareName(sender)
        if not senderName then return end

        local kind, payload = message:match("^(%a+):(.*)$")
        if kind == "HELLO" then
            local priority = tonumber(payload) or PRIORITY_AUTO
            HandleHello(senderName, priority)
        end
    end)

    HH.Events:On("PLAYER_ENTERING_WORLD", function()
        PruneLiveRoster()
        ScheduleHello()
        ScheduleLockAttempt()
    end)

    HH.Events:On("GROUP_ROSTER_UPDATE", function()
        PruneLiveRoster()
        ScheduleHello()
        -- A composition change can either trigger a fresh lock (we just
        -- hit expected size) or invalidate the current one (we left the
        -- instance). ReconcileLockState handles both — but go through
        -- the debounce so a burst of events coalesces.
        ScheduleLockAttempt()
        if lockedRoster and not GetExpectedGroupSize() then
            -- Player just left the instance; unlock immediately without
            -- waiting for the debounce so the live roster takes over.
            Unlock()
        end
    end)
end
