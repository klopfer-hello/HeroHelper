--[[
    HeroHelper - TBC Anniversary Edition
    Core Module - Main addon framework and initialization

    This module handles:
    - Addon initialization and event registration
    - Global state management
    - Saved variables / defaults
    - Slash command handling
    - Module coordination via an event bus
]]

local ADDON_NAME, HH = ...

-- Global addon namespace
HeroHelper = HH

-- Version info
HH.VERSION = "0.1.0"
HH.BUILD = "TBC-Anniversary"

-- Addon state
HH.initialized = false
HH.debugMode = false

-- Shared runtime state
HH.State = {
    -- Player capability
    isShaman           = false,   -- player class == SHAMAN
    spellID            = nil,     -- 2825 (Bloodlust) or 32182 (Heroism) depending on faction
    spellName          = nil,     -- localized spell name
    buffSpellName      = nil,     -- Sated (Alliance) or Exhaustion (Horde) debuff to detect recent BL/Hero

    -- Combat / encounter
    inCombat           = false,
    currentBossID      = nil,     -- Database key of the boss currently being fought (nil if none)
    currentBossName    = nil,     -- Localized/display name
    pullTime           = nil,     -- GetTime() when the pull was detected

    -- Trigger evaluation
    triggered          = false,   -- true once the reminder has been shown for this pull
    lastHPCheck        = 0,
}

-- Color codes for chat messages
HH.Colors = {
    addon     = "|cFFFF7D1A",   -- Orange (Heroism/BL flavor)
    success   = "|cFF00FF00",
    warning   = "|cFFFFFF00",
    error     = "|cFFFF0000",
    info      = "|cFFAAAAAA",
    highlight = "|cFFFFD700",
    alliance  = "|cFF0070DD",
    horde     = "|cFFC41F3B",
}

-- ============================================================================
-- Event Bus (pub/sub)
-- Modules subscribe in Initialize(); Core fires without knowing who listens.
-- ============================================================================

HH.Events = {}
local busListeners = {}

function HH.Events:On(event, fn)
    if not busListeners[event] then busListeners[event] = {} end
    table.insert(busListeners[event], fn)
end

function HH.Events:Fire(event, ...)
    if busListeners[event] then
        for _, fn in ipairs(busListeners[event]) do fn(...) end
    end
end

-- ============================================================================
-- Spell constants (resolved at login)
-- ============================================================================

-- Heroism (Alliance shaman) and Bloodlust (Horde shaman). Both apply a raid-wide
-- 30 % haste buff and leave a debuff on every affected player that prevents the
-- same effect from being re-applied for 10 minutes:
--   * Sated (57724)       -- Heroism
--   * Exhaustion (57723)  -- Bloodlust
-- We use these debuffs to suppress the reminder when BL/Hero is still "on
-- cooldown for the raid" from the player's point of view.
HH.SPELL_HEROISM   = 32182  -- Alliance
HH.SPELL_BLOODLUST = 2825   -- Horde
HH.DEBUFF_SATED      = 57724
HH.DEBUFF_EXHAUSTION = 57723

-- ============================================================================
-- Default saved variables
-- ============================================================================

local defaultDB = {
    settings = {
        enabled       = true,
        showMinimap   = true,
        minimapAngle  = 225,
        debug         = false,
        -- Master toggle for 5-man dungeon boss alerts. Off by default so
        -- players who installed HeroHelper for raid content don't suddenly
        -- start getting BL reminders on Hellfire Ramparts trash. When on,
        -- every TBC dungeon boss fires a "pull" trigger (the default);
        -- individual dungeon bosses can still be overridden via the
        -- Bosses config tab like raid bosses.
        dungeonPullAlerts = false,
    },
}

local defaultCharDB = {
    -- Per-character settings (reminder button position, size, sound, etc.)
    settings = {
        -- Reminder button
        button = {
            -- Locked by default so the button is immediately armed to cast.
            -- Use /hh unlock (or the config checkbox) to reposition it, then
            -- re-lock when done. /hh test temporarily force-unlocks so you
            -- can drag a preview button into place.
            locked       = true,
            size         = 40,
            -- Point on screen (nil until the user drags the button)
            point        = "CENTER",
            relativePoint= "CENTER",
            x            = 0,
            y            = 0,
        },
        -- Sound cue played when the reminder triggers. Value is a LibSharedMedia
        -- sound key; nil means "no sound".
        sound          = "HeroHelper: Raid Warning",
        soundEnabled   = true,
        -- Keybind macrotext override (empty string = default /cast)
        macrotext      = nil,
        -- Automatically hide button as soon as BL/Hero debuff is detected on the
        -- player (prevents spamming the reminder if a second shaman already cast).
        hideOnDebuff   = true,
        -- After-cast auto-hide fade time (seconds)
        postCastFade   = 2,
        -- Minimum seconds between showing the reminder twice on the same pull
        reminderCooldown = 30,
    },

    -- Per-boss trigger overrides.
    -- Keyed by boss ID (see modules/Database.lua). Shape:
    --   { type = "pull" | "hp" | "phase",
    --     hp   = 50,                      -- (type == "hp") threshold in percent
    --     phase= 2,                       -- (type == "phase") phase index
    --     enabled = true,                 -- if false this boss never triggers
    --   }
    -- Missing keys fall back to the default encoded in the database.
    bosses = {},
}

-- ============================================================================
-- Utility Functions
-- ============================================================================

function HH:Print(msg, color)
    color = color or HH.Colors.info
    print(HH.Colors.addon .. "HeroHelper|r: " .. color .. msg .. "|r")
end

function HH:Debug(msg)
    if HH.debugMode or (HH.db and HH.db.settings and HH.db.settings.debug) then
        print(HH.Colors.addon .. "HeroHelper|r [DEBUG]: |cFFAAAAAA" .. tostring(msg) .. "|r")
    end
end

function HH:TableCopy(t)
    local copy = {}
    for k, v in pairs(t) do
        if type(v) == "table" then
            copy[k] = HH:TableCopy(v)
        else
            copy[k] = v
        end
    end
    return copy
end

-- Recursive default-merging so new defaults added in later versions populate
-- into existing saved variables without overwriting user tweaks.
local function MergeDefaults(target, source)
    for k, v in pairs(source) do
        if type(v) == "table" then
            if type(target[k]) ~= "table" then target[k] = {} end
            MergeDefaults(target[k], v)
        elseif target[k] == nil then
            target[k] = v
        end
    end
end

-- ============================================================================
-- Capability detection
-- ============================================================================

-- Only Shamans ever cast Heroism / Bloodlust. Non-shaman characters still see
-- the addon load (so the minimap button + config panel work), but the reminder
-- logic and trigger engine are short-circuited.
function HH:UpdatePlayerCapability()
    local _, class = UnitClass("player")
    HH.State.isShaman = (class == "SHAMAN")

    if not HH.State.isShaman then
        HH.State.spellID   = nil
        HH.State.spellName = nil
        return
    end

    local faction = UnitFactionGroup("player")
    if faction == "Alliance" then
        HH.State.spellID       = HH.SPELL_HEROISM
        HH.State.buffSpellName = GetSpellInfo(HH.DEBUFF_SATED)
    else
        HH.State.spellID       = HH.SPELL_BLOODLUST
        HH.State.buffSpellName = GetSpellInfo(HH.DEBUFF_EXHAUSTION)
    end
    HH.State.spellName = GetSpellInfo(HH.State.spellID)
end

function HH:IsActive()
    return HH.State.isShaman and HH.db and HH.db.settings.enabled
end

-- Returns true while Sated/Exhaustion is on the player (cannot receive
-- BL/Hero again yet).
function HH:HasExhaustionDebuff()
    if not HH.State.buffSpellName then return false end
    for i = 1, 40 do
        local name = UnitDebuff("player", i)
        if not name then break end
        if name == HH.State.buffSpellName then
            return true
        end
    end
    return false
end

-- Returns true if BL/Hero is currently on cooldown for the player.
function HH:IsSpellOnCooldown()
    if not HH.State.spellName then return false end
    local start, duration = GetSpellCooldown(HH.State.spellName)
    if not start or not duration then return false end
    -- A duration > 1.5 means the spell is actually on cooldown (GCD returns 1.5)
    if duration > 1.5 and (start + duration) > GetTime() then
        return true
    end
    return false
end

-- ============================================================================
-- Saved variables init
-- ============================================================================

local function InitializeSavedVariables()
    if not HeroHelperDB then
        HeroHelperDB = HH:TableCopy(defaultDB)
    else
        MergeDefaults(HeroHelperDB, defaultDB)
    end

    if not HeroHelperCharDB then
        HeroHelperCharDB = HH:TableCopy(defaultCharDB)
    else
        MergeDefaults(HeroHelperCharDB, defaultCharDB)
    end

    HH.db      = HeroHelperDB
    HH.chardb  = HeroHelperCharDB
end

-- ============================================================================
-- Initialization
-- ============================================================================

local function InitializeAddon()
    if HH.initialized then return end

    InitializeSavedVariables()
    HH:UpdatePlayerCapability()

    -- Initialize modules (each registers its own event bus listeners)
    if HH.Database       then HH.Database:Initialize() end
    if HH.Detection      then HH.Detection:Initialize() end
    if HH.Triggers       then HH.Triggers:Initialize() end
    if HH.ReminderButton then HH.ReminderButton:Initialize() end
    if HH.Minimap        then HH.Minimap:Initialize() end
    if HH.Config         then HH.Config:Initialize() end

    HH.initialized = true

    if HH.State.isShaman then
        HH:Print("Loaded. Type " .. HH.Colors.highlight .. "/hh|r for options.", HH.Colors.success)
    else
        HH:Print("Loaded (non-shaman: reminder disabled, config still accessible).", HH.Colors.info)
    end
end

-- ============================================================================
-- Event handling (shared frame, pub/sub fanout)
-- ============================================================================

local eventFrame = CreateFrame("Frame", "HeroHelperEventFrame")

local events = {
    "ADDON_LOADED",
    "PLAYER_LOGIN",
    "PLAYER_ENTERING_WORLD",

    -- Combat lifecycle (used by Detection + Triggers)
    "PLAYER_REGEN_ENABLED",
    "PLAYER_REGEN_DISABLED",

    -- Target scanning fallback (when no boss mod is present)
    "PLAYER_TARGET_CHANGED",
    "UPDATE_MOUSEOVER_UNIT",

    -- Phase detection via emotes
    "CHAT_MSG_MONSTER_YELL",
    "CHAT_MSG_RAID_BOSS_EMOTE",
    "CHAT_MSG_RAID_BOSS_WHISPER",

    -- Combat log for health tracking + spell-cast phase triggers
    "COMBAT_LOG_EVENT_UNFILTERED",

    -- Keep UI fresh on spec/cd changes
    "SPELL_UPDATE_COOLDOWN",
    "UNIT_AURA",
}

for _, event in ipairs(events) do
    eventFrame:RegisterEvent(event)
end

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == ADDON_NAME then
            InitializeAddon()
        end
        return
    end

    if event == "PLAYER_LOGIN" then
        if not HH.initialized then InitializeAddon() end
        HH:UpdatePlayerCapability()
        HH.Events:Fire("PLAYER_LOGIN")
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        HH.Events:Fire("PLAYER_ENTERING_WORLD", ...)
        return
    end

    if event == "PLAYER_REGEN_DISABLED" then
        HH.State.inCombat = true
        HH.Events:Fire("COMBAT_START")
        return
    end

    if event == "PLAYER_REGEN_ENABLED" then
        HH.State.inCombat = false
        HH.State.triggered = false
        HH.State.pullTime = nil
        HH.State.currentBossID = nil
        HH.State.currentBossName = nil
        HH.Events:Fire("COMBAT_END")
        return
    end

    if event == "PLAYER_TARGET_CHANGED" then
        HH.Events:Fire("TARGET_CHANGED")
        return
    end

    if event == "UPDATE_MOUSEOVER_UNIT" then
        HH.Events:Fire("MOUSEOVER_CHANGED")
        return
    end

    if event == "CHAT_MSG_MONSTER_YELL"
       or event == "CHAT_MSG_RAID_BOSS_EMOTE"
       or event == "CHAT_MSG_RAID_BOSS_WHISPER" then
        local text, source = ...
        HH.Events:Fire("BOSS_YELL", text, source)
        return
    end

    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        HH.Events:Fire("CLEU", CombatLogGetCurrentEventInfo())
        return
    end

    if event == "SPELL_UPDATE_COOLDOWN" then
        HH.Events:Fire("COOLDOWN_CHANGED")
        return
    end

    if event == "UNIT_AURA" then
        local unit = ...
        if unit == "player" then
            HH.Events:Fire("PLAYER_AURA_CHANGED")
        end
        return
    end
end)

-- ============================================================================
-- Slash commands
-- ============================================================================

SLASH_HEROHELPER1 = "/hh"
SLASH_HEROHELPER2 = "/herohelper"

SlashCmdList["HEROHELPER"] = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")

    if msg == "" or msg == "config" or msg == "options" then
        if HH.Config and HH.Config.Toggle then HH.Config:Toggle() end
        return
    end

    if msg == "lock" then
        HH.chardb.settings.button.locked = true
        if HH.ReminderButton and HH.ReminderButton.ApplyLock then
            HH.ReminderButton:ApplyLock()
        end
        HH:Print("Reminder button locked.", HH.Colors.success)
        return
    end

    if msg == "unlock" then
        HH.chardb.settings.button.locked = false
        if HH.ReminderButton and HH.ReminderButton.ApplyLock then
            HH.ReminderButton:ApplyLock()
        end
        HH:Print("Reminder button unlocked.", HH.Colors.success)
        return
    end

    if msg == "test" then
        if HH.ReminderButton and HH.ReminderButton.ToggleTestMode then
            HH.ReminderButton:ToggleTestMode()
            if HH.ReminderButton:IsTestMode() then
                HH:Print("Test mode ON — drag the button into place, then run /hh test again to disable.", HH.Colors.info)
            else
                HH:Print("Test mode OFF.", HH.Colors.info)
            end
        end
        return
    end

    if msg == "debug" then
        HH.db.settings.debug = not HH.db.settings.debug
        HH:Print("Debug mode " .. (HH.db.settings.debug and "ON" or "OFF") .. ".", HH.Colors.info)
        return
    end

    -- /hh mobtest [HP%] — arms the reminder button for the current target
    -- and fires it when that mob drops below the HP threshold. Toggle off
    -- with a second /hh mobtest (or it auto-disables on fire / 10-min
    -- safety timeout). Intentionally command-line only — not surfaced in
    -- the config panel.
    if msg == "mobtest" or msg:match("^mobtest%s") then
        if HH.Triggers and HH.Triggers.IsMobTestActive and HH.Triggers:IsMobTestActive() then
            HH.Triggers:DisableMobTest()
            return
        end
        local arg = msg:match("^mobtest%s+(%d+)$")
        local threshold = tonumber(arg) or 50
        if HH.Triggers and HH.Triggers.EnableMobTest then
            HH.Triggers:EnableMobTest(threshold)
        end
        return
    end

    if msg == "reset" then
        HH.chardb.settings.button.point         = "CENTER"
        HH.chardb.settings.button.relativePoint = "CENTER"
        HH.chardb.settings.button.x             = 0
        HH.chardb.settings.button.y             = 0
        if HH.ReminderButton and HH.ReminderButton.ApplyPosition then
            HH.ReminderButton:ApplyPosition()
        end
        HH:Print("Reminder button position reset.", HH.Colors.success)
        return
    end

    HH:Print("Commands:", HH.Colors.highlight)
    HH:Print("  /hh             - open options")
    HH:Print("  /hh lock | unlock - lock/unlock reminder button")
    HH:Print("  /hh reset       - reset button position")
    HH:Print("  /hh test        - toggle test mode (button stays visible for positioning)")
    HH:Print("  /hh mobtest [%] - fire reminder when current target drops below HP% (default 50)")
    HH:Print("  /hh debug       - toggle debug output")
end
