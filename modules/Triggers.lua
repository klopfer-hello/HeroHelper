--[[
    HeroHelper - Triggers Module

    Evaluates "is it time to cast Heroism / Bloodlust right now?" once per
    frame while the player is in combat against a known boss. Fires
    HEROHELPER_TRIGGER on the event bus when all of the following are true:

    * The player is a Shaman who knows BL/Hero
    * The addon is enabled
    * There is a current boss ID (set by the Detection module)
    * BL/Hero is not on cooldown for the player
    * The player does not have Sated/Exhaustion
    * The trigger condition in the boss config evaluates to true:
        - type == "pull"  -> fire immediately once a pull is detected
        - type == "hp"    -> fire when the boss HP% <= threshold
        - type == "phase" -> fire when a boss yell / emote matches the phase
                             entry text (see Database.yells), or when the
                             configured CLEU spell cast is observed
    * The reminder has not already been triggered for this pull

    After firing, the trigger latches until combat ends or the boss resets.
]]

local ADDON_NAME, HH = ...

HH.Triggers = {}
local T = HH.Triggers

-- Accumulated phase number per pull (phase detection via yells is monotonic)
local currentPhase = 1

-- HP polling interval (seconds) — we don't want to run UnitHealth scans every
-- frame. 0.25s gives us responsive triggering without measurable cost.
local HP_POLL_INTERVAL = 0.25
local hpPollTicker

-- ============================================================================
-- Public check
-- ============================================================================

local function IsReady()
    if not HH:IsActive() then return false end
    if not HH.State.isShaman then return false end
    if not HH.State.inCombat then return false end
    if not HH.State.currentBossID then return false end
    if HH.State.triggered then return false end
    if HH:HasExhaustionDebuff() then return false end
    if HH:IsSpellOnCooldown() then return false end
    return true
end

-- Try to fire the reminder based on the trigger config for the current boss.
-- evaluateExtra is a function returning true if the current boss's trigger
-- condition evaluates positively. Each trigger type supplies its own
-- evaluateExtra via the caller in :Check().
local function TryFire(reason)
    if not IsReady() then return end

    HH.State.triggered = true
    HH:Debug("TRIGGER FIRED: " .. tostring(reason))
    HH.Events:Fire("HEROHELPER_TRIGGER", HH.State.currentBossID, reason)
end

-- ============================================================================
-- Per-trigger-type evaluation
-- ============================================================================

-- Trigger evaluation that runs on EITHER BOSS_PULL or COMBAT_START.
--
-- Why both: the unit-scan fallback in Detection runs on TARGET_CHANGED /
-- MOUSEOVER_CHANGED, which can fire while the player is still out of
-- combat (e.g. tab-targeting a dungeon boss before pulling). When that
-- happens, BOSS_PULL fires before COMBAT_START, IsReady() bails on the
-- inCombat check, and the trigger silently misses. After combat starts,
-- Detection:ScanUnits early-returns because currentBossID is already
-- locked, so BOSS_PULL never re-fires — the trigger window is lost.
--
-- This function is idempotent: HH.State.triggered latches once we fire,
-- so calling it twice is safe. Both BOSS_PULL and COMBAT_START call it
-- and whichever happens second produces the actual fire.
local function EvaluatePullTrigger()
    if not HH.State.currentBossID then return end

    local cfg = HH.Database:GetTriggerConfig(HH.State.currentBossID)
    if not cfg then return end

    if cfg.type == "pull" then
        TryFire("pull")
    end

    -- Kick off the HP poll ticker only when there is an HP-type trigger.
    -- This keeps non-HP fights completely idle.
    if cfg.type == "hp" then
        T:StartHPPoll()
    end
end

-- BOSS_PULL handler. Resets per-pull state and runs the trigger evaluator.
local function OnBossPull(bossID)
    currentPhase = 1
    HH.State.triggered = false
    EvaluatePullTrigger()
end

-- "hp": poll the boss unit and fire when HP% drops below the threshold.
function T:StartHPPoll()
    if hpPollTicker then return end
    hpPollTicker = C_Timer.NewTicker(HP_POLL_INTERVAL, function()
        if not HH.State.currentBossID or HH.State.triggered or not HH.State.inCombat then
            T:StopHPPoll()
            return
        end
        local cfg = HH.Database:GetTriggerConfig(HH.State.currentBossID)
        if not cfg or cfg.type ~= "hp" then
            T:StopHPPoll()
            return
        end
        local hp = HH.Detection:GetCurrentBossHPPct()
        if hp and hp <= (cfg.hp or 35) then
            TryFire("hp " .. math.floor(hp) .. "%")
            T:StopHPPoll()
        end
    end)
end

function T:StopHPPoll()
    if hpPollTicker then
        hpPollTicker:Cancel()
        hpPollTicker = nil
    end
end

-- "phase": advance currentPhase based on boss yell text, then fire when the
-- running phase counter reaches the configured target. Yell matching is a
-- simple case-insensitive substring search against the patterns declared in
-- Database.yells per boss.
local function OnBossYell(text)
    if not HH.State.currentBossID or not text then return end
    local boss = HH.Database:Get(HH.State.currentBossID)
    if not boss or not boss.yells then return end

    local lower = text:lower()
    -- Iterate yells in phase order so we advance linearly.
    local phases = {}
    for p in pairs(boss.yells) do table.insert(phases, p) end
    table.sort(phases)

    for _, phase in ipairs(phases) do
        if phase > currentPhase then
            local pattern = boss.yells[phase]
            if type(pattern) == "string" and lower:find(pattern:lower(), 1, true) then
                currentPhase = phase
                HH:Debug("Phase advanced to " .. phase .. " via yell: " .. pattern)

                local cfg = HH.Database:GetTriggerConfig(HH.State.currentBossID)
                if cfg and cfg.type == "phase" and currentPhase >= (cfg.phase or 2) then
                    TryFire("phase " .. currentPhase)
                end
                return
            end
        end
    end
end

-- ============================================================================
-- Mob test mode (/hh mobtest)
-- ============================================================================
--
-- A command-line diagnostic that arms the reminder button for any arbitrary
-- mob (not just bosses in the database). The player targets a mob, runs
-- `/hh mobtest`, and the reminder fires as soon as that mob drops below the
-- configured HP threshold (default 50%). This exists so you can verify the
-- full "mob → HP poll → reminder button" pipeline on dummies or trash mobs
-- without needing to pull a real raid boss.
--
-- Design notes:
--   * We capture the target's *GUID* at invocation time, not just the unit
--     token, so the mode survives retargeting / losing tab-target. The poll
--     scans every unit token we can cheaply check (target, focus, mouseover,
--     boss1..5, raid/party targets) for a GUID match each tick.
--   * The fire path calls RB:Show() directly instead of going through
--     HEROHELPER_TRIGGER, so the test works outside combat, on non-shamans,
--     and regardless of BL cooldown / Sated state. This is intentional — it's
--     a diagnostic, not a real trigger.
--   * A 10-minute safety timeout auto-disables the mode so a forgotten test
--     can't leak a ticker forever.

local mobTest = {
    active    = false,
    mode      = nil,    -- "hp" or "pull"
    guid      = nil,
    name      = nil,
    threshold = 50,
    ticker    = nil,
    expires   = nil,
}

local MOBTEST_POLL_INTERVAL = 0.25
local MOBTEST_TIMEOUT       = 600   -- seconds (10 minutes)

-- Candidate unit tokens to check each tick for a GUID match.
local MOBTEST_SCAN_UNITS = {
    "target", "focus", "mouseover",
    "boss1", "boss2", "boss3", "boss4", "boss5",
}

local function FindUnitByGUID(guid)
    if not guid then return nil end
    for _, unit in ipairs(MOBTEST_SCAN_UNITS) do
        if UnitExists(unit) and UnitGUID(unit) == guid then
            return unit
        end
    end
    -- Group-target scan — supports both the TBC and modern group APIs.
    local raidN = (GetNumRaidMembers and GetNumRaidMembers()) or 0
    if raidN > 0 or (IsInRaid and IsInRaid()) then
        local n = math.max(raidN, (GetNumGroupMembers and GetNumGroupMembers()) or 0)
        for i = 1, n do
            local u = "raid" .. i .. "target"
            if UnitExists(u) and UnitGUID(u) == guid then return u end
        end
    else
        local partyN = (GetNumPartyMembers and GetNumPartyMembers()) or 0
        for i = 1, partyN do
            local u = "party" .. i .. "target"
            if UnitExists(u) and UnitGUID(u) == guid then return u end
        end
    end
    return nil
end

function T:IsMobTestActive()
    return mobTest.active
end

function T:DisableMobTest(reason)
    if not mobTest.active then return end
    mobTest.active = false
    mobTest.mode   = nil
    if mobTest.ticker then
        mobTest.ticker:Cancel()
        mobTest.ticker = nil
    end
    HH:Print("Mob test disabled" .. (reason and (": " .. reason) or "") .. ".", HH.Colors.info)
end

-- Fires the reminder for the current mobtest target. Shared by the HP-mode
-- poll and the pull-mode COMBAT_START hook.
local function FireMobTestReminder(reason)
    HH:Print(("Mob test: %s — firing reminder."):format(reason), HH.Colors.success)
    -- RB:Show reads HH.State.currentBossName for the label.
    HH.State.currentBossName = mobTest.name
    if HH.ReminderButton and HH.ReminderButton.Show then
        HH.ReminderButton:Show()
    end
end

local function PollMobTest()
    if not mobTest.active then return end

    if GetTime() > (mobTest.expires or 0) then
        T:DisableMobTest("timed out after 10 minutes")
        return
    end

    local unit = FindUnitByGUID(mobTest.guid)
    if not unit then return end

    if UnitIsDeadOrGhost(unit) then
        T:DisableMobTest("target died before reaching threshold")
        return
    end

    local maxHP = UnitHealthMax(unit)
    if not maxHP or maxHP == 0 then return end
    local pct = (UnitHealth(unit) / maxHP) * 100

    if pct <= mobTest.threshold then
        FireMobTestReminder(("%s at %d%%"):format(mobTest.name or "target", pct))
        T:DisableMobTest()
    end
end

-- COMBAT_START handler for pull-mode mobtest. Fires the reminder the
-- instant the player enters combat after `/hh mobtest pull`. Independent
-- of the BOSS_PULL pipeline, so it works on any trash mob.
local function OnMobTestCombatStart()
    if not mobTest.active or mobTest.mode ~= "pull" then return end
    FireMobTestReminder("combat started (" .. (mobTest.name or "pull test") .. ")")
    T:DisableMobTest()
end

function T:EnableMobTest(arg)
    if mobTest.active then
        T:DisableMobTest("restarting")
    end

    -- Pull mode: arm a one-shot listener that fires on the next COMBAT_START.
    -- A target is optional — if you have one we use its name as the label,
    -- otherwise the reminder shows "Mob test pull". Useful for verifying
    -- the pull-trigger pipeline against any trash mob without needing a
    -- specific target acquired before pulling.
    if arg == "pull" then
        mobTest.active    = true
        mobTest.mode      = "pull"
        mobTest.guid      = nil
        mobTest.name      = (UnitExists("target") and UnitName("target")) or "Mob test pull"
        mobTest.expires   = GetTime() + MOBTEST_TIMEOUT
        -- Light timeout sweeper — no per-tick polling needed in pull mode,
        -- just a single periodic check to clean up if the player never pulls.
        if mobTest.ticker then mobTest.ticker:Cancel() end
        mobTest.ticker = C_Timer.NewTicker(5, function()
            if mobTest.active and GetTime() > (mobTest.expires or 0) then
                T:DisableMobTest("timed out after 10 minutes")
            end
        end)
        HH:Print(("Mob test (pull) armed — fires on next combat start (%s)."):format(
            mobTest.name), HH.Colors.success)
        return true
    end

    -- HP mode (default): poll target HP until it crosses the threshold.
    if not UnitExists("target") then
        HH:Print("Mob test: no target selected. Target a mob first.", HH.Colors.warning)
        return false
    end
    if UnitIsDeadOrGhost("target") then
        HH:Print("Mob test: target is dead.", HH.Colors.warning)
        return false
    end
    if not UnitCanAttack("player", "target") then
        HH:Print("Mob test: target is not attackable.", HH.Colors.warning)
        return false
    end

    local threshold = tonumber(arg) or 50
    if threshold < 1  then threshold = 1  end
    if threshold > 99 then threshold = 99 end

    mobTest.active    = true
    mobTest.mode      = "hp"
    mobTest.guid      = UnitGUID("target")
    mobTest.name      = UnitName("target")
    mobTest.threshold = threshold
    mobTest.expires   = GetTime() + MOBTEST_TIMEOUT

    HH:Print(("Mob test armed for %s at <= %d%% HP."):format(mobTest.name, threshold), HH.Colors.success)

    if mobTest.ticker then mobTest.ticker:Cancel() end
    mobTest.ticker = C_Timer.NewTicker(MOBTEST_POLL_INTERVAL, PollMobTest)
    return true
end

-- ============================================================================
-- Lifecycle
-- ============================================================================

function T:Initialize()
    HH.Events:On("BOSS_PULL", OnBossPull)
    HH.Events:On("BOSS_YELL", function(text, source) OnBossYell(text) end)
    -- COMBAT_START re-runs the pull evaluator. Covers the case where the
    -- player tab-targeted the boss before pulling — BOSS_PULL fired
    -- pre-combat (when IsReady fails on the inCombat gate) and never re-fired
    -- because Detection's currentBossID dedup blocks a second BOSS_PULL.
    HH.Events:On("COMBAT_START", function()
        EvaluatePullTrigger()
        OnMobTestCombatStart()
    end)
    HH.Events:On("COMBAT_END", function()
        currentPhase = 1
        HH.State.triggered = false
        T:StopHPPoll()
    end)
end
