--[[
    HeroHelper - Reminder Module

    Visual reminder that pops up when BL/Hero should be cast. Purely a
    non-protected Frame — the ACTUAL cast is not wired to clicking this
    frame. Casting happens through the persistent "HeroHelperCast" macro
    the addon creates in the player's macro list: the user binds a key to
    that macro once in Escape → Key Bindings → Macros, and presses it when
    the reminder pops.

    Why this shape:
      * Clickable secure-cast buttons are heavily restricted in combat on
        TBC Classic 2.5.5. Toggling their visibility, hit area, enabled
        state, or macro reference from Lua mid-combat is variously blocked
        or silently ignored. We tried every secure-handler variant
        (SecureHandlerBaseTemplate.Execute, SecureHandlerStateTemplate
        with _onstate-display, RegisterStateDriver visibility, ...) and
        none of them reliably flips a protected frame's visibility from
        a mid-combat callsite on this client.
      * Decoupling visual from cast sidesteps the problem entirely. A
        plain Frame can be Shown/Hidden freely at any time, and WoW's
        native macro keybind system handles the combat-safe cast.
      * This is the same pattern ElvUI, ShamanPower, and RestedXP use
        for their combat reminders.

    The persistent macro "HeroHelperCast" is created per-character by
    EnsureMacro() at Initialize and is refreshed whenever the spell /
    user override changes. On first login, the user is asked to set a
    keybind for it.
]]

local ADDON_NAME, HH = ...

HH.ReminderButton = {}
local RB = HH.ReminderButton

local container
local visible   = false
local testMode  = false

-- ============================================================================
-- Sound registration
-- ============================================================================
-- Mirrors the ShamanPower pattern: the sound names match the keys ShamanPower
-- uses for its Totem Twisting alert, and we register them into LSM via
-- direct MediaTable insertion (LSM:Register rejects the "Sound\\" prefix,
-- so ShamanPower and we both bypass it). Sharing keys with ShamanPower lets
-- both addons reuse the same LSM media registry — anything ShamanPower
-- adds becomes available here and vice-versa.

local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

local HH_SOUNDS = {
    ["Raid Warning"]          = [[Sound\Interface\RaidWarning.ogg]],
    ["Alarm Clock Warning 1"] = [[Sound\Interface\AlarmClockWarning1.ogg]],
    ["Alarm Clock Warning 2"] = [[Sound\Interface\AlarmClockWarning2.ogg]],
    ["Alarm Clock Warning 3"] = [[Sound\Interface\AlarmClockWarning3.ogg]],
    ["Ready Check"]           = [[Sound\Interface\ReadyCheck.ogg]],
    ["Map Ping"]              = [[Sound\Interface\MapPing.ogg]],
    ["PVP Flag Taken"]        = [[Sound\Interface\PVPFlagTaken.ogg]],
    ["Quest Failed"]          = [[Sound\Interface\igQuestFailed.ogg]],
    ["Level Up"]              = [[Sound\Interface\LevelUp.ogg]],
}

-- The order we want entries to appear in the dropdown.
local SOUND_ORDER = {
    "Raid Warning",
    "Alarm Clock Warning 1",
    "Alarm Clock Warning 2",
    "Alarm Clock Warning 3",
    "Ready Check",
    "Map Ping",
    "PVP Flag Taken",
    "Quest Failed",
    "Level Up",
}

local function RegisterSounds()
    -- Direct MediaTable insert (bypasses LSM:Register's "interface" path
    -- prefix check). Same trick ShamanPower uses.
    if LSM and LSM.MediaTable and LSM.MediaTable.sound then
        for name, path in pairs(HH_SOUNDS) do
            LSM.MediaTable.sound[name] = path
        end
    end
end

-- Resolves a sound key to a playable file path. Falls back to our local
-- HH_SOUNDS table if LSM isn't available or the key isn't registered.
local function ResolveSoundFile(key)
    if not key then return HH_SOUNDS["Raid Warning"] end
    if LSM then
        local file = LSM:Fetch("sound", key, true)
        if file then return file end
    end
    return HH_SOUNDS[key] or HH_SOUNDS["Raid Warning"]
end

-- Returns the full list of sound keys the user can pick from. When LSM is
-- available (the normal case — we embed it), this returns EVERY sound any
-- loaded addon has registered with LSM, sorted alphabetically. That way
-- HeroHelper's sound picker matches ShamanPower's and every other
-- SharedMedia-aware addon: whatever BigWigs / ShamanPower / Details /
-- etc. register becomes selectable here. Falls back to our own 9 keys if
-- LSM didn't load.
function RB:GetSoundList()
    if LSM and LSM.List then
        -- LSM:List returns a sorted array-table of registered keys for the
        -- given media type. Safe to call every time the picker rebuilds.
        local names = LSM:List("sound")
        if names and #names > 0 then
            return names
        end
    end
    -- Fallback: our curated order.
    local list = {}
    for _, name in ipairs(SOUND_ORDER) do
        table.insert(list, name)
    end
    return list
end

-- ============================================================================
-- Persistent cast macro
-- ============================================================================
-- The addon creates a per-character macro named "HeroHelperCast" with the
-- cast body. The user binds a key to it in Escape → Key Bindings → Macros.
-- Pressing the bound key fires BL/Hero; the reminder frame is purely
-- visual and never wired to perform the cast itself.

local MACRO_NAME = "HeroHelperCast"

local function ComputeCastText()
    if not HH.State.spellName then return nil end
    local override = HH.chardb and HH.chardb.settings and HH.chardb.settings.macrotext
    if override and override ~= "" then
        return override
    end
    return "/cast [@player] " .. HH.State.spellName
end

-- Creates or updates the HeroHelperCast macro. Returns the macro name on
-- success, nil on failure (macro slots full, spell unknown, in combat).
local function EnsureMacro()
    if InCombatLockdown() then return nil end
    local castText = ComputeCastText()
    if not castText then return nil end

    local icon = "INV_Misc_QuestionMark"
    if HH.State.spellID then
        local tex = select(3, GetSpellInfo(HH.State.spellID))
        if tex then icon = tex end
    end

    local index = GetMacroIndexByName and GetMacroIndexByName(MACRO_NAME) or 0
    if index and index > 0 then
        if EditMacro then
            EditMacro(index, MACRO_NAME, icon, castText)
        end
        return MACRO_NAME
    end
    if CreateMacro then
        local newIndex = CreateMacro(MACRO_NAME, icon, castText, 1)
        if newIndex and newIndex > 0 then
            return MACRO_NAME
        end
    end
    return nil
end

-- ============================================================================
-- Frame creation
-- ============================================================================

-- Migrates legacy sound keys from the pre-LSM naming scheme
-- ("HeroHelper: Raid Warning") to the shared LSM keys ("Raid Warning").
-- Runs once per login; idempotent.
local function MigrateSoundKey()
    local s = HH.chardb and HH.chardb.settings
    if not s or not s.sound then return end
    local stripped = s.sound:gsub("^HeroHelper: ", "")
    if stripped ~= s.sound then
        s.sound = stripped
    end
end

function RB:Initialize()
    if not HH.State.isShaman then return end

    MigrateSoundKey()
    RegisterSounds()
    self:CreateFrame()
    self:ApplyPosition()
    self:ApplySize()
    self:RefreshMacro()

    -- Event subscriptions
    HH.Events:On("HEROHELPER_TRIGGER",   function() RB:Show() end)
    HH.Events:On("COMBAT_END",           function() RB:Hide() end)
    HH.Events:On("PLAYER_LOGIN",         function()
        RB:RefreshMacro()
        RB:MaybeShowFirstLoginHint()
    end)
    HH.Events:On("PLAYER_ENTERING_WORLD", function() RB:RefreshMacro() end)
    HH.Events:On("PLAYER_AURA_CHANGED", function()
        if HH.chardb.settings.hideOnDebuff and HH:HasExhaustionDebuff() then
            RB:Hide()
        end
    end)
    HH.Events:On("COOLDOWN_CHANGED", function()
        if visible and HH:IsSpellOnCooldown() then
            local fade = HH.chardb.settings.postCastFade or 2
            C_Timer.After(fade, function() RB:Hide() end)
        end
    end)
end

function RB:CreateFrame()
    if container then return end

    container = CreateFrame("Frame", "HeroHelperReminderContainer", UIParent)
    container:SetFrameStrata("HIGH")
    container:SetFrameLevel(100)
    container:SetClampedToScreen(true)
    container:SetMovable(true)
    container:SetSize(40, 40)
    container:EnableMouse(true)
    container:RegisterForDrag("LeftButton")
    container:Hide()

    -- Icon (spell texture)
    local icon = container:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints(container)
    local spellID = HH.State.spellID or HH.SPELL_HEROISM
    local spellTexture = select(3, GetSpellInfo(spellID)) or "Interface\\Icons\\Spell_Nature_Bloodlust"
    icon:SetTexture(spellTexture)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    container.icon = icon

    -- Pulse overlay (alpha-animated on OnUpdate).
    local pulse = container:CreateTexture(nil, "OVERLAY", nil, 1)
    pulse:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    pulse:SetBlendMode("ADD")
    pulse:SetVertexColor(1, 0.55, 0.0, 1)
    container.pulse = pulse

    -- Thin orange border
    local function edge(point1, point2, horiz)
        local t = container:CreateTexture(nil, "OVERLAY", nil, 2)
        t:SetPoint(point1)
        t:SetPoint(point2)
        if horiz then t:SetHeight(2) else t:SetWidth(2) end
        t:SetColorTexture(1, 0.49, 0.10, 1)
        return t
    end
    edge("TOPLEFT",    "TOPRIGHT",    true)
    edge("BOTTOMLEFT", "BOTTOMRIGHT", true)
    edge("TOPLEFT",    "BOTTOMLEFT",  false)
    edge("TOPRIGHT",   "BOTTOMRIGHT", false)

    -- Label (boss name above)
    local label = container:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    label:SetPoint("BOTTOM", container, "TOP", 0, 4)
    label:SetTextColor(1, 0.82, 0)
    container.label = label

    -- Drag to reposition (only when unlocked or in test mode)
    container:SetScript("OnDragStart", function(self)
        if testMode or not HH.chardb.settings.button.locked then
            self:StartMoving()
        end
    end)
    container:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relativePoint, x, y = self:GetPoint()
        HH.chardb.settings.button.point         = point
        HH.chardb.settings.button.relativePoint = relativePoint
        HH.chardb.settings.button.x             = x
        HH.chardb.settings.button.y             = y
    end)

    container:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("|cFFFF7D1AHeroHelper|r", 1, 1, 1)
        if HH.State.currentBossName then
            GameTooltip:AddLine(HH.State.currentBossName, 0.7, 0.7, 0.7)
        end
        if testMode or not HH.chardb.settings.button.locked then
            GameTooltip:AddLine("Drag to move", 0.5, 0.5, 0.5)
        end
        GameTooltip:Show()
    end)
    container:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Pulse animation (alpha-modulated)
    local elapsed = 0
    container:SetScript("OnUpdate", function(self, e)
        if not self.pulse then return end
        elapsed = elapsed + e
        local a = 0.55 + 0.45 * (1 + math.sin(elapsed * 6)) * 0.5
        self.pulse:SetAlpha(a)
    end)
end

-- ============================================================================
-- Apply config
-- ============================================================================

function RB:ApplyPosition()
    if not container then return end
    local s = HH.chardb.settings.button
    container:ClearAllPoints()
    container:SetPoint(s.point or "CENTER", UIParent, s.relativePoint or "CENTER", s.x or 0, s.y or 0)
end

function RB:ApplySize()
    if not container then return end
    local size = HH.chardb.settings.button.size or 40
    container:SetSize(size, size)
    if container.pulse then
        local overshoot = math.floor(size * 0.50 + 0.5)
        container.pulse:ClearAllPoints()
        container.pulse:SetPoint("TOPLEFT",     container, "TOPLEFT",     -overshoot,  overshoot)
        container.pulse:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT",  overshoot, -overshoot)
    end
end

function RB:ApplyLock()
    if not container then return end
    -- Lock state only affects whether drag-to-move is allowed. Cast
    -- arming is decoupled — it's always available via the user's
    -- keybind on the HeroHelperCast macro.
    container:SetMovable(true) -- always movable; OnDragStart gates it
end

-- Refreshes the HeroHelperCast macro body (out of combat) so it matches
-- the player's current spell / user override. Also refreshes the icon
-- overlay. Called on init, PLAYER_LOGIN, PLAYER_ENTERING_WORLD, and
-- whenever the user changes macrotext in settings.
function RB:RefreshMacro()
    if InCombatLockdown() then return end
    EnsureMacro()
    if HH.State.spellID and container and container.icon then
        local tex = select(3, GetSpellInfo(HH.State.spellID))
        if tex then container.icon:SetTexture(tex) end
    end
end

-- Kept for backwards compatibility with existing callers (Config panel,
-- slash commands). Semantically now the same as RefreshMacro.
function RB:ApplyMacrotext()
    self:RefreshMacro()
end

-- ============================================================================
-- Show / hide
-- ============================================================================

function RB:Show()
    if not container then return end
    if testMode then self:SetTestMode(false) end
    container.label:SetText(HH.State.currentBossName or "HeroHelper")
    visible = true
    container:Show()
    self:PlaySound()
end

function RB:Hide()
    if not container then return end
    if testMode then return end
    visible = false
    container:Hide()
end

function RB:IsVisible()
    return visible or testMode
end

-- ============================================================================
-- Test mode
-- ============================================================================

function RB:IsTestMode()
    return testMode
end

function RB:SetTestMode(enable)
    if not container then return end
    if enable then
        testMode = true
        container.label:SetText("TEST")
        container:Show()
        self:PlaySound()
    else
        testMode = false
        if not visible then
            container:Hide()
        end
    end
end

function RB:ToggleTestMode()
    self:SetTestMode(not testMode)
end

function RB:TestShow()
    self:ToggleTestMode()
end

-- ============================================================================
-- First-login hint
-- ============================================================================
-- The first time a shaman loads the addon after this refactor, prompt
-- them to set a keybind. The hint is sticky via a SavedVariables flag
-- so it only appears once per character.

function RB:MaybeShowFirstLoginHint()
    if not HH.chardb.settings then return end
    if HH.chardb.settings.keybindHintShown then return end
    HH.chardb.settings.keybindHintShown = true

    HH:Print("Casting is via your own keybind - bind a key to the " ..
             HH.Colors.highlight .. MACRO_NAME .. "|r " ..
             HH.Colors.info .. "macro in " ..
             HH.Colors.highlight .. "Escape > Key Bindings > Macros|r.",
             HH.Colors.info)
end

-- ============================================================================
-- Sound playback
-- ============================================================================

local function PlaySoundEntry(key)
    -- Resolve the key to a file path via LSM (falls back to our own
    -- HH_SOUNDS table if LSM isn't loaded or the key is unknown).
    local file = ResolveSoundFile(key)
    if file then
        local willPlay = PlaySoundFile(file, "Master")
        if willPlay then return true end
    end

    -- Last-resort fallback: numeric SoundKit ID for the raid-warning alert.
    -- Universally present in TBC 2.5.5.
    PlaySound(8959, "Master")
    return true
end

function RB:PlaySound()
    if not HH.chardb.settings.soundEnabled then return end
    PlaySoundEntry(HH.chardb.settings.sound)
end

function RB:PreviewSound()
    PlaySoundEntry(HH.chardb.settings.sound)
end
