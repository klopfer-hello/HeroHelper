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

-- party/raid targets are added dynamically per scan (indexed by group size).
-- Supports both the modern (GetNumGroupMembers/IsInRaid) and legacy
-- (GetNumRaidMembers/GetNumPartyMembers) APIs so the code is robust across
-- TBC Anniversary client revisions.
local function AddGroupTargets(list)
    local raidN  = (GetNumRaidMembers and GetNumRaidMembers()) or 0
    if raidN > 0 or (IsInRaid and IsInRaid()) then
        for i = 1, math.max(raidN, (GetNumGroupMembers and GetNumGroupMembers()) or 0) do
            table.insert(list, "raid" .. i .. "target")
        end
        return
    end
    local partyN = (GetNumPartyMembers and GetNumPartyMembers()) or ((GetNumGroupMembers and GetNumGroupMembers()) or 0)
    for i = 1, partyN do
        table.insert(list, "party" .. i .. "target")
    end
end

-- ============================================================================
-- Core scan
-- ============================================================================

function Detection:ScanUnits()
    if HH.State.currentBossID then return end -- already locked in

    local units = {}
    for _, u in ipairs(SCAN_UNITS) do table.insert(units, u) end
    AddGroupTargets(units)

    for _, unit in ipairs(units) do
        if UnitExists(unit) and not UnitIsDeadOrGhost(unit) and UnitCanAttack("player", unit) then
            local name = UnitName(unit)
            local id = name and HH.Database:LookupByName(name)
            if id then
                self:SetCurrentBoss(id, name, unit)
                return
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

-- BigWigs broadcasts module-level "OnBossEngage" etc. messages via its loader
-- callback registry. We hook both the loader (BigWigsLoader) and the core
-- (BigWigs itself) because TBC BigWigs routes engage messages through
-- different handlers depending on version.
function Detection:HookBigWigs()
    local BW = _G.BigWigs or _G.BigWigsLoader
    if not BW then return false end

    -- BigWigs exposes a RegisterMessage method on its addon object
    if type(BW.RegisterMessage) == "function" then
        local ok, err = pcall(function()
            BW:RegisterMessage("BigWigs_OnBossEngage", function(_, module, diff)
                local bossName = module and (module.displayName or module.moduleName)
                local id = bossName and HH.Database:LookupByName(bossName)
                if id then
                    Detection:SetCurrentBoss(id, bossName)
                end
            end)
            BW:RegisterMessage("BigWigs_OnBossDisable", function(_, module)
                HH.State.currentBossID   = nil
                HH.State.currentBossName = nil
            end)
        end)
        if ok then
            HH:Debug("BigWigs engage hook installed")
            return true
        else
            HH:Debug("BigWigs hook failed: " .. tostring(err))
        end
    end
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
        dbm:RegisterCallback("pull", function(event, mod, delay, ...)
            local bossName = mod and (mod.combatInfo and mod.combatInfo.name or mod.localization and mod.localization.general and mod.localization.general.name)
            if not bossName and mod then bossName = mod.id end
            local id = bossName and HH.Database:LookupByName(bossName)
            if id then
                Detection:SetCurrentBoss(id, bossName)
            end
        end)
        dbm:RegisterCallback("kill", function() end)
        dbm:RegisterCallback("wipe", function()
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

    local units = {}
    for _, u in ipairs(SCAN_UNITS) do table.insert(units, u) end
    AddGroupTargets(units)

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
-- Initialization
-- ============================================================================

function Detection:Initialize()
    -- Unit scan fallback
    HH.Events:On("TARGET_CHANGED",    function() Detection:ScanUnits() end)
    HH.Events:On("MOUSEOVER_CHANGED", function() Detection:ScanUnits() end)
    HH.Events:On("COMBAT_START",      function() Detection:ScanUnits() end)

    -- Boss mod hookup is deferred: their addons may load after ours.
    HH.Events:On("PLAYER_ENTERING_WORLD", function()
        if not Detection._hookedBW  then Detection._hookedBW  = Detection:HookBigWigs() end
        if not Detection._hookedDBM then Detection._hookedDBM = Detection:HookDBM()     end
    end)
end
