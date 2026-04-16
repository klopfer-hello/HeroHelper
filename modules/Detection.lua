--[[
    HeroHelper - Detection Module

    Identifies the boss the player is currently fighting. TBC Classic has no
    ENCOUNTER_START / ENCOUNTER_END events, so we combine three sources:

    1. BigWigs (via the "BigWigs_OnBossEngage" / "BigWigs_OnBossDisable"
       messages broadcast through its callback handler)
    2. Deadly Boss Mods (via DBM's "pull" callback on its event dispatcher)
    3. Fallback unit scanning: every time target/mouseover/focus/raid targets
       change, scan them for a name that matches an entry in the Database.

    Whichever source fires first sets HH.State.currentBossID and fires the
    "BOSS_PULL" event on the internal event bus.
]]

local ADDON_NAME, HH = ...

HH.Detection = {}
local Detection = HH.Detection

local CLASSIFICATION_BOSS = "worldboss"
local CLASSIFICATION_ELITE_PRIORITY = { "worldboss", "rareelite", "elite" }

-- Set of units we scan when no boss mod has already identified a boss.
-- "boss1..4" are included because BigWigs / DBM may populate them in TBC
-- Anniversary via their own shims even though Blizzard does not.
local SCAN_UNITS = {
    "target", "focus", "mouseover",
    "boss1", "boss2", "boss3", "boss4", "boss5",
}

-- ============================================================================
-- Shared unit-list builder
-- ============================================================================

-- Returns a fresh list of every unit token worth scanning: the static core
-- set (target, focus, mouseover, boss1..5) plus dynamic raid/party targets.
-- Supports both the modern (GetNumGroupMembers/IsInRaid) and legacy
-- (GetNumRaidMembers/GetNumPartyMembers) APIs so the code is robust across
-- TBC Anniversary client revisions.
--
-- Used by ScanUnits(), GetCurrentBossHPPct(), and Triggers:FindUnitByGUID().
function Detection:GetScanUnits()
    local units = {}
    for _, u in ipairs(SCAN_UNITS) do units[#units + 1] = u end

    local raidN = (GetNumRaidMembers and GetNumRaidMembers()) or 0
    if raidN > 0 or (IsInRaid and IsInRaid()) then
        local n = math.max(raidN, (GetNumGroupMembers and GetNumGroupMembers()) or 0)
        for i = 1, n do units[#units + 1] = "raid" .. i .. "target" end
        return units
    end

    local partyN = (GetNumPartyMembers and GetNumPartyMembers())
              or ((GetNumGroupMembers and GetNumGroupMembers()) or 0)
    for i = 1, partyN do units[#units + 1] = "party" .. i .. "target" end
    return units
end

-- ============================================================================
-- Core scan
-- ============================================================================

function Detection:ScanUnits()
    if HH.State.currentBossID then return end -- already locked in

    local units = self:GetScanUnits()

    -- Captured once per scan: lets DB:LookupByName disambiguate name
    -- collisions like Kael'thas (TK raid vs MgT 5-man).
    local zone = GetRealZoneText and GetRealZoneText() or nil

    for _, unit in ipairs(units) do
        if UnitExists(unit) and not UnitIsDeadOrGhost(unit) and UnitCanAttack("player", unit) then
            local name = UnitName(unit)
            local id = name and HH.Database:LookupByName(name, zone)
            if id then
                -- Dungeon bosses require the unit to be in combat before we
                -- lock in. Without this check, pulling trash near an idle
                -- dungeon boss causes a false BOSS_PULL because the scan
                -- picks up the nearby boss via raid/party targets.
                local boss = HH.Database:Get(id)
                if boss and boss.isDungeon and not UnitAffectingCombat(unit) then
                    -- Skip: boss is in the database but not yet engaged.
                else
                    self:SetCurrentBoss(id, name, unit)
                    return
                end
            end
        end
    end
end

function Detection:SetCurrentBoss(bossID, displayName, unit)
    if HH.State.currentBossID == bossID then return end

    HH.State.currentBossID   = bossID
    HH.State.currentBossName = displayName or HH.Database:Get(bossID).name
    HH.State.pullTime        = HH.State.pullTime or GetTime()

    HH:Debug("BOSS_PULL: " .. HH.State.currentBossName .. " (" .. bossID .. ")")
    HH.Events:Fire("BOSS_PULL", bossID, unit)
end

-- ============================================================================
-- BigWigs integration
-- ============================================================================

-- BigWigs broadcasts module-level "BigWigs_OnBossEngage" / "_OnBossDisable"
-- messages via a CallbackHandler-1.0 registry embedded on BigWigs (or the
-- loader). CallbackHandler's RegisterMessage signature is:
--
--     registry.RegisterMessage(subscriber, messageName, handler)
--
-- where `subscriber` is any unique identifier owned by the *subscriber*, not
-- the broadcaster. Calling it via method syntax (`BW:RegisterMessage(...)`)
-- passes BW itself as the subscriber and BigWigs refuses it with:
--
--   "attempted to register a function to BigWigsLoader, you might be using
--    : instead of . to register the callback."
--
-- We use dot syntax and pass our own addon namespace (HH) as the subscriber.
function Detection:HookBigWigs()
    local BW = _G.BigWigs or _G.BigWigsLoader
    if not BW or type(BW.RegisterMessage) ~= "function" then return false end

    local ok, err = pcall(function()
        BW.RegisterMessage(HH, "BigWigs_OnBossEngage", function(_, module, diff)
            local bossName = module and (module.displayName or module.moduleName)
            local zone = GetRealZoneText and GetRealZoneText() or nil
            local id = bossName and HH.Database:LookupByName(bossName, zone)
            if id then
                Detection:SetCurrentBoss(id, bossName)
            end
        end)
        BW.RegisterMessage(HH, "BigWigs_OnBossDisable", function(_, module)
            HH.State.currentBossID   = nil
            HH.State.currentBossName = nil
        end)
    end)
    if ok then
        HH:Debug("BigWigs engage hook installed")
        return true
    end
    HH:Debug("BigWigs hook failed: " .. tostring(err))
    return false
end

-- ============================================================================
-- DBM integration
-- ============================================================================

-- DBM exposes DBM.RegisterCallback(self, "pull", handler) as of the TBC build.
function Detection:HookDBM()
    local dbm = _G.DBM
    if not dbm or type(dbm.RegisterCallback) ~= "function" then return false end

    local ok, err = pcall(function()
        -- DBM prefixes all callback event names with "DBM_". The callback
        -- function receives (event, mod, delay, synced, startHp).
        dbm:RegisterCallback("DBM_Pull", function(event, mod, delay, ...)
            local bossName = mod and (mod.combatInfo and mod.combatInfo.name or mod.localization and mod.localization.general and mod.localization.general.name)
            if not bossName and mod then bossName = mod.id end
            local zone = GetRealZoneText and GetRealZoneText() or nil
            local id = bossName and HH.Database:LookupByName(bossName, zone)
            if id then
                Detection:SetCurrentBoss(id, bossName)
            else
                HH:Debug("DBM_Pull: no DB match for '" .. tostring(bossName) .. "'")
            end
        end)
        dbm:RegisterCallback("DBM_Kill", function() end)
        dbm:RegisterCallback("DBM_Wipe", function()
            HH.State.currentBossID   = nil
            HH.State.currentBossName = nil
        end)
    end)
    if ok then
        HH:Debug("DBM callbacks installed")
        return true
    else
        HH:Debug("DBM hook failed: " .. tostring(err))
    end
    return false
end

-- ============================================================================
-- HP polling (used by the Triggers module's HP% threshold logic)
-- ============================================================================

-- Returns the HP percentage of the current boss across all units we can see,
-- or nil if no valid unit is found.
function Detection:GetCurrentBossHPPct()
    if not HH.State.currentBossID then return nil end
    local wantName = HH.State.currentBossName

    local units = self:GetScanUnits()

    for _, unit in ipairs(units) do
        if UnitExists(unit) and UnitName(unit) == wantName and not UnitIsDeadOrGhost(unit) then
            local hp, max = UnitHealth(unit), UnitHealthMax(unit)
            if max and max > 0 then
                return (hp / max) * 100
            end
        end
    end
    return nil
end

-- ============================================================================
-- In-combat rescan ticker
-- ============================================================================
--
-- Covers the chained-pull scenario: the player is already in combat (from
-- trash) and engages a boss without generating a TARGET_CHANGED or
-- MOUSEOVER_CHANGED event. A lightweight periodic scan fills the gap until
-- a boss is identified or combat ends.

local RESCAN_INTERVAL = 0.5   -- seconds between scans
local rescanTicker

local function StartRescanTicker()
    if rescanTicker then return end
    rescanTicker = C_Timer.NewTicker(RESCAN_INTERVAL, function()
        if HH.State.currentBossID or not HH.State.inCombat then
            if rescanTicker then rescanTicker:Cancel(); rescanTicker = nil end
            return
        end
        Detection:ScanUnits()
    end)
end

local function StopRescanTicker()
    if rescanTicker then
        rescanTicker:Cancel()
        rescanTicker = nil
    end
end

-- ============================================================================
-- Initialization
-- ============================================================================

function Detection:Initialize()
    -- Unit scan fallback
    HH.Events:On("TARGET_CHANGED",    function() Detection:ScanUnits() end)
    HH.Events:On("MOUSEOVER_CHANGED", function() Detection:ScanUnits() end)
    HH.Events:On("COMBAT_START",      function()
        Detection:ScanUnits()
        if not HH.State.currentBossID then
            StartRescanTicker()
        end
    end)
    HH.Events:On("COMBAT_END", function() StopRescanTicker() end)

    -- Boss mod hookup is deferred: their addons may load after ours.
    HH.Events:On("PLAYER_ENTERING_WORLD", function()
        if not Detection._hookedBW  then Detection._hookedBW  = Detection:HookBigWigs() end
        if not Detection._hookedDBM then Detection._hookedDBM = Detection:HookDBM()     end
    end)
end
