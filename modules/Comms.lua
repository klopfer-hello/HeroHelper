--[[
    HeroHelper - Comms Module

    Multi-shaman coordination via the addon-message channel. When two or
    more HeroHelper-using shamans are in the same group, only ONE of them
    casts BL/Hero on each pull — the lowest-priority player who's still
    alive at fire time wins, the others suppress their reminder.

    Protocol (CHAT_MSG_ADDON, prefix "HEROHELPER"):

        BID:<bossID>:<priority>:<reason>
            "I'm planning to fire on this boss with this priority. My
             name is implicit from the addon-message sender field."

    Priority numbers:
       1 = Primary    (always casts when alive)
       2 = Secondary  (casts if Primary is dead)
       3 = Backup     (casts if Primary and Secondary are dead)
      99 = Auto       (no explicit role; alphabetical fallback)

    Flow:
      1. Triggers.lua TryFire calls C:Coordinate(bossID, reason, fire).
      2. Comms broadcasts a BID with the player's priority and arms a
         500ms grace window. The pending fire's bidders list seeds with
         self at our own priority.
      3. Incoming BIDs from other HeroHelper users append to the bidders
         list (or update an existing entry from the same sender).
      4. After 500ms: each bidder is re-checked for alive status, then
         the lowest-priority alive bidder wins (ties broken by case-
         insensitive alphabetical name). If that's me, fire; otherwise
         drop the reminder with a one-line "deferred to" chat note.

    Solo / no group / coordinate-disabled: the fire runs immediately with
    no broadcast and no delay.

    Backward compatibility:
      Older HeroHelper builds emit `BID:<bossID>:<reason>` (no priority).
      The decoder treats a non-numeric second field as Auto priority (99),
      so old senders are simply auto bidders. The reverse is also OK: old
      receivers parse the new format and ignore everything past bossID,
      using their alphabetical fallback.
]]

local ADDON_NAME, HH = ...

HH.Comms = {}
local C = HH.Comms

local ADDON_PREFIX = "HEROHELPER"
local COORD_WINDOW = 0.5  -- seconds; raid addon messages should arrive
                          -- well within 100-200ms in the same instance,
                          -- so 500ms is conservative.

local PRIORITY_AUTO = 99

-- Single in-flight coordination state. Cleared when the window resolves.
-- bidders is a list of { name, priority } entries; alive status is
-- evaluated lazily inside the resolve callback so it always reflects
-- the latest raid frame state.
local pendingFire = nil  -- { bossID, reason, fireFn, bidders }

-- ============================================================================
-- Helpers
-- ============================================================================

-- Returns the addon-message channel to broadcast on, or nil if solo.
local function GetGroupChannel()
    -- Prefer the modern API but fall back to TBC's group counters so this
    -- works on every flavor of Classic.
    if IsInRaid and IsInRaid() then return "RAID" end
    if (GetNumRaidMembers and GetNumRaidMembers() or 0) > 0 then return "RAID" end
    if IsInGroup and IsInGroup() then return "PARTY" end
    if (GetNumPartyMembers and GetNumPartyMembers() or 0) > 0 then return "PARTY" end
    return nil
end

-- Strip a "-Realm" suffix from an addon-message sender name. Cross-realm
-- isn't a thing in TBC Classic PvE but defensive trimming costs nothing.
local function BareName(name)
    if not name then return nil end
    return name:match("^([^-]+)") or name
end

-- Case-insensitive name precedence. Lower sorts win the alphabetical
-- tiebreaker among bidders sharing the same priority.
local function NameLessThan(a, b)
    return (a:lower()) < (b:lower())
end

-- Returns true if a player by `name` is currently alive. Scans the player
-- itself, raid units, and party units. Returns true on miss so an unknown
-- bidder isn't silently filtered out (better double-cast than miss).
local function IsBidderAlive(name)
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

    return true -- unknown bidder; assume alive (safer than dropping)
end

-- Calls SendAddonMessage via whichever API the current client exposes.
-- TBC Classic 2.5.5 ships both the legacy global and C_ChatInfo.
local function SendBid(message, channel)
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        return pcall(C_ChatInfo.SendAddonMessage, ADDON_PREFIX, message, channel)
    end
    if SendAddonMessage then
        return pcall(SendAddonMessage, ADDON_PREFIX, message, channel)
    end
    return false
end

-- ============================================================================
-- Bid handling
-- ============================================================================

local function HandleBid(senderName, bossID, priority)
    if not pendingFire then return end
    if pendingFire.bossID ~= bossID then return end

    local me = BareName(UnitName("player"))
    if not me or senderName == me then return end

    -- Update existing entry if this sender already bid (defensive against
    -- duplicate broadcasts on lossy channels), otherwise append.
    for _, b in ipairs(pendingFire.bidders) do
        if b.name == senderName then
            b.priority = priority
            return
        end
    end
    table.insert(pendingFire.bidders, { name = senderName, priority = priority })
end

-- Picks the chosen bidder according to priority + alive status. Lower
-- priority wins; ties broken by alphabetical name. Returns the bidder
-- table or nil if no candidate is alive.
local function PickWinner(bidders)
    local chosen = nil
    for _, b in ipairs(bidders) do
        if IsBidderAlive(b.name) then
            if not chosen
               or b.priority < chosen.priority
               or (b.priority == chosen.priority and NameLessThan(b.name, chosen.name)) then
                chosen = b
            end
        end
    end
    return chosen
end

-- Returns a bidder list sorted by priority (then alphabetical name),
-- which is the same order PickWinner walks. Used by the raid-chat
-- announcement to print "winner > backup1 > backup2".
local function SortBiddersByPriority(bidders)
    local sorted = {}
    for _, b in ipairs(bidders) do
        sorted[#sorted + 1] = { name = b.name, priority = b.priority }
    end
    table.sort(sorted, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        return NameLessThan(a.name, b.name)
    end)
    return sorted
end

-- Posts the resolved Heroism order to raid/party chat. Called by the
-- chosen winner only — every HeroHelper instance computes the same
-- winner from the same bidder list, so this naturally deduplicates
-- across the raid without needing a separate handshake.
local function BroadcastOrder(bidders, channel)
    local sorted = SortBiddersByPriority(bidders)
    if #sorted == 0 then return end

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
-- Public API
-- ============================================================================

-- Coordinates the firing of a reminder with other HeroHelper shamans in
-- the group. `fireFn` is the callback that actually shows the reminder.
-- It will be invoked either immediately (solo / coord disabled) or after
-- the COORD_WINDOW delay if this player is the chosen bidder by priority
-- + alive status.
function C:Coordinate(bossID, reason, fireFn)
    if not (HH.db and HH.db.settings and HH.db.settings.coordinateShamans) then
        fireFn()
        return
    end

    local channel = GetGroupChannel()
    if not channel then
        fireFn()
        return
    end

    if pendingFire then
        -- A previous bid is still in flight on this pull. Drop the second
        -- request — HH.State.triggered already latched upstream so the
        -- caller won't retry. The original window resolves on its own.
        return
    end

    local me = BareName(UnitName("player"))
    local myPriority = (HH.db.settings.shamanPriority or PRIORITY_AUTO)

    pendingFire = {
        bossID  = bossID,
        reason  = reason,
        fireFn  = fireFn,
        channel = channel,
        bidders = {
            -- Self is always the first bidder; the resolve callback re-
            -- evaluates alive status at fire time.
            { name = me, priority = myPriority },
        },
    }

    SendBid("BID:" .. tostring(bossID) .. ":" .. tostring(myPriority) .. ":" .. tostring(reason), channel)
    HH:Debug(("Coordinate: bid broadcast on %s (boss=%s, priority=%d)"):format(
        channel, tostring(bossID), myPriority))

    C_Timer.After(COORD_WINDOW, function()
        local p = pendingFire
        pendingFire = nil
        if not p then return end

        local winner = PickWinner(p.bidders)
        if not winner then
            -- No alive bidder at all (e.g., everyone wiped during the
            -- window). Fall through and fire — at worst the player tries
            -- to cast and IsReady's own checks will reject if needed.
            HH:Debug("Coordinate: no alive bidder, firing self as fallback")
            p.fireFn()
            return
        end

        if winner.name == me then
            HH:Debug(("Coordinate: won bid (priority=%d)"):format(winner.priority))
            -- Only the chosen winner posts the raid-chat order, so the
            -- announcement is naturally one-per-pull even with multiple
            -- HeroHelper users in the group.
            if HH.db.settings.announceCoordination then
                BroadcastOrder(p.bidders, p.channel)
            end
            p.fireFn()
        else
            HH:Print(("Heroism deferred to %s."):format(winner.name),
                HH.Colors.info)
            HH:Debug(("Coordinate: deferred to %s (priority=%d)"):format(
                winner.name, winner.priority))
        end
    end)
end

-- ============================================================================
-- Lifecycle
-- ============================================================================

function C:Initialize()
    -- Register the addon-message prefix. Modern Classic exposes this on
    -- C_ChatInfo; older builds expose a global. Use whichever exists.
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
        if kind == "BID" then
            -- New format: bossID:priority:reason
            -- Old format: bossID:reason   (priority field absent)
            -- The second `:`-separated field is treated as priority if it
            -- parses as a number, otherwise we assume the old format and
            -- default to AUTO priority.
            local bossID, second = payload:match("^([^:]+):?([^:]*)")
            if bossID then
                local priority = tonumber(second) or PRIORITY_AUTO
                HandleBid(senderName, bossID, priority)
            end
        end
    end)
end
