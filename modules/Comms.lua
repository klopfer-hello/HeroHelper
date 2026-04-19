--[[
    HeroHelper - Comms Module

    Manual multi-shaman coordination over the addon-message channel.

    Design (user-controlled, no automation):

      * Every HeroHelper user broadcasts HELLO when the group roster
        changes. Each client maintains a live roster of the other
        HeroHelper-using shamans in the group and their role priorities.
      * **Without an active lock, every shaman gets their own reminder.**
        No election, no suppression. AmIElectedWinner returns true.
      * The raid leader (or any user) types `/hh roster lock` when they
        want to freeze the hero order. That:
            - Snapshots the live roster into a locked roster.
            - Runs the election once (lowest priority alive, alphabetical
              tiebreak) to pick the primary fire-er.
            - Announces the resolved order to raid/party chat once.
            - From now on, only the elected-winner's HeroHelper fires;
              every other HeroHelper-using shaman suppresses its
              reminder for the rest of the run.
      * Alive-aware fallback: the election is re-evaluated against the
        locked roster every time a reminder is about to fire, so if
        the primary dies mid-fight the secondary's HeroHelper takes
        over, and if the secondary also dies the backup fires. Order
        is determined by role priority, not by the current
        HEROHELPER_TRIGGER event.
      * `/hh roster unlock` drops the lock — everyone goes back to
        firing their own reminder.

    Protocol (CHAT_MSG_ADDON, prefix "HEROHELPER"):

        HELLO:<priority>
            "I'm a HeroHelper user. My role priority is <priority>.
             My player name is implicit from the addon-message sender."

    Priority numbers:
       1 = Primary    (elected when alive)
       2 = Secondary  (elected if Primary is dead)
       3 = Backup     (elected if Primary and Secondary are dead)
      99 = Auto       (no explicit role; alphabetical fallback)
]]

local ADDON_NAME, HH = ...

HH.Comms = {}
local C = HH.Comms

local ADDON_PREFIX = "HEROHELPER"

local PRIORITY_AUTO = 99

-- Live roster: HELLO-discovered HeroHelper users currently in the group.
-- Maintained continuously so `/hh roster lock` has an up-to-date snapshot.
local roster = {}                  -- name -> priority

-- Locked roster: snapshot of `roster` taken by C:Lock(). nil when no
-- lock is active. When non-nil, the election runs against this fixed
-- snapshot — late joiners are not added until the next manual lock.
local lockedRoster = nil           -- name -> priority OR nil

-- Debounce flag so a flurry of GROUP_ROSTER_UPDATE events coalesces
-- into one HELLO broadcast.
local pendingHello = false

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

-- ============================================================================
-- Roster maintenance
-- ============================================================================

-- Removes live-roster entries for players no longer in the group. The
-- locked roster is intentionally NOT pruned — the order stands until
-- /hh roster unlock.
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
-- in which ElectFrom walks. Used by the chat announcement and the
-- /hh roster diagnostic.
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

-- Returns true if THIS player should fire reminders.
--   * No lock in effect → everyone fires (return true).
--   * Lock in effect → only the currently-elected (alive) winner fires.
--     Election re-evaluates on every call, so alive-aware fallback is
--     automatic (primary dies → secondary fires → backup fires).
function C:AmIElectedWinner()
    if not lockedRoster then
        return true
    end

    local me = BareName(UnitName("player"))
    if not me then return true end

    local winner = ElectFrom(lockedRoster)
    if not winner then
        -- Everyone in the locked roster is dead. Fall through and fire
        -- as a last resort — IsReady's own checks will block it if the
        -- player is dead too.
        return true
    end
    return winner.name == me
end

function C:GetActiveRosterSorted()
    return SortedRoster(lockedRoster or roster)
end

function C:GetElectedWinner()
    if not lockedRoster then return nil end
    local w = ElectFrom(lockedRoster)
    return w and w.name or nil
end

function C:IsLocked()
    return lockedRoster ~= nil
end

-- ============================================================================
-- Chat announcement
-- ============================================================================

-- Posts the resolved Heroism order to raid/party chat using the locked
-- roster. Called exactly once by the player who ran /hh roster lock.
local function PostOrderToChat()
    local sorted = SortedRoster(lockedRoster or {})
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
-- Lock / unlock  (user-driven via /hh roster lock | unlock)
-- ============================================================================

-- Snapshots the current live roster, runs the election, and announces
-- the resolved order to chat. Returns (ok, reason) — false + reason
-- string on failure so the slash command can report to the player.
function C:Lock()
    if lockedRoster then
        return false, "already locked - run `/hh roster unlock` first"
    end
    if not GetGroupChannel() then
        return false, "not in a group"
    end

    PruneLiveRoster()

    local count = 0
    local snapshot = {}
    for name, p in pairs(roster) do
        snapshot[name] = p
        count = count + 1
    end
    if count == 0 then
        return false, "no HeroHelper users discovered yet - wait a moment and retry"
    end

    lockedRoster = snapshot
    HH:Debug(("Coordinate: election LOCKED with %d HeroHelper user(s)"):format(count))

    -- Only the user who ran /hh roster lock posts the order. The locking
    -- player's HELLO priority is irrelevant for announcement duty.
    PostOrderToChat()
    return true
end

function C:Unlock()
    if not lockedRoster then
        return false, "not currently locked"
    end
    lockedRoster = nil
    HH:Debug("Coordinate: election UNLOCKED")
    return true
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

local function HandleHello(senderName, priority)
    local me = BareName(UnitName("player"))
    if not me or senderName == me then return end

    local prev = roster[senderName]
    roster[senderName] = priority
    if prev ~= priority then
        HH:Debug(("Coordinate: HELLO from %s (priority=%d)"):format(senderName, priority))
    end
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
    end)

    HH.Events:On("GROUP_ROSTER_UPDATE", function()
        PruneLiveRoster()
        ScheduleHello()
    end)
end
