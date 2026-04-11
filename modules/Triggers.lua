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

-- "pull": fire as soon as we detect the pull — implemented as an immediate
-- TryFire() on BOSS_PULL for this kind.
local function OnBossPull(bossID)
    currentPhase = 1
    HH.State.triggered = false

    local cfg = HH.Database:GetTriggerConfig(bossID)
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
-- Lifecycle
-- ============================================================================

function T:Initialize()
    HH.Events:On("BOSS_PULL", OnBossPull)
    HH.Events:On("BOSS_YELL", function(text, source) OnBossYell(text) end)
    HH.Events:On("COMBAT_END", function()
        currentPhase = 1
        HH.State.triggered = false
        T:StopHPPoll()
    end)
end
