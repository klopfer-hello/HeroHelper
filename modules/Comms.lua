--[[
    HeroHelper - Comms Module

    Multi-shaman coordination via the addon-message channel. When two or
    more HeroHelper-using shamans are in the same group, only ONE of them
    casts BL/Hero on each pull — the alphabetically lowest player name
    wins, the others suppress their reminder for that pull.

    Protocol (CHAT_MSG_ADDON, prefix "HEROHELPER"):

        BID:<bossID>:<reason>
            "I'm planning to fire on this boss for this reason. My name
             is implicit from the addon-message sender field."

    Flow:
      1. Triggers.lua TryFire calls C:Coordinate(bossID, reason, fire).
      2. Comms broadcasts a BID and arms a 500ms grace window.
      3. Incoming BIDs from other HeroHelper users are compared by sender
         name. If a name alphabetically before mine arrives, my pending
         fire is marked suppressed.
      4. After 500ms: if not suppressed, the fire callback runs; otherwise
         the fire is silently dropped (with a one-line chat note).

    Solo / no group / coordinate-disabled: the fire runs immediately with
    no broadcast and no delay.

    Limitations (acceptable for v1):
      * Coordination is decided by name precedence, not by who is most
        likely to actually cast. If the chosen shaman is dead/AFK, the
        backup shaman won't notice. A future improvement could add a
        500ms-after-fire "still here?" handshake.
      * Only HeroHelper users participate. A non-HeroHelper shaman is
        invisible to the coordinator and may double-up the BL.
]]

local ADDON_NAME, HH = ...

HH.Comms = {}
local C = HH.Comms

local ADDON_PREFIX = "HEROHELPER"
local COORD_WINDOW = 0.5  -- seconds; raid addon messages should arrive
                          -- well within 100-200ms in the same instance,
                          -- so 500ms is conservative.

-- Single in-flight coordination state. Cleared when the window resolves.
local pendingFire = nil  -- { bossID, reason, fireFn, suppressed, suppressor }

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

-- Case-insensitive name precedence. Lower sorts win the bid.
local function NameLessThan(a, b)
    return (a:lower()) < (b:lower())
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

local function HandleBid(senderName, bossID)
    if not pendingFire then return end
    if pendingFire.bossID ~= bossID then return end

    local me = BareName(UnitName("player"))
    if not me or senderName == me then return end

    if NameLessThan(senderName, me) then
        pendingFire.suppressed = true
        pendingFire.suppressor = senderName
    end
end

-- ============================================================================
-- Public API
-- ============================================================================

-- Coordinates the firing of a reminder with other HeroHelper shamans in
-- the group. `fireFn` is the callback that actually shows the reminder.
-- It will be invoked either immediately (solo / coord disabled) or after
-- the COORD_WINDOW delay if no other shaman bid earlier in the alphabet.
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

    pendingFire = {
        bossID     = bossID,
        reason     = reason,
        fireFn     = fireFn,
        suppressed = false,
        suppressor = nil,
    }

    SendBid("BID:" .. tostring(bossID) .. ":" .. tostring(reason), channel)
    HH:Debug("Coordinate: bid broadcast on " .. channel .. " for " .. tostring(bossID))

    C_Timer.After(COORD_WINDOW, function()
        local p = pendingFire
        pendingFire = nil
        if not p then return end
        if p.suppressed then
            HH:Print(("Heroism deferred to %s."):format(p.suppressor or "another shaman"),
                HH.Colors.info)
            HH:Debug("Coordinate: suppressed by " .. tostring(p.suppressor))
        else
            p.fireFn()
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
            local bossID = payload:match("^([^:]+)")
            if bossID then HandleBid(senderName, bossID) end
        end
    end)
end
