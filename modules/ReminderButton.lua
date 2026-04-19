--[[
    HeroHelper - Reminder Module

    Purely informational reminder. A non-protected Frame pops up with the
    spell icon + pulsing glow + boss-name label when it's time to cast
    Heroism / Bloodlust, and hides again when the cast goes off (or
    combat ends, or the Sated/Exhaustion debuff is detected).

    The addon does NOT cast for you. It's a timing reminder — you already
    have Heroism/Bloodlust bound somewhere (action bar, keybind, whatever)
    and you trigger it the way you normally would. This keeps the addon
    out of all the combat-lockdown / protected-frame landmines on
    TBC Classic 2.5.5 that plagued earlier clickable-reminder designs.
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
    self:RefreshIcon()

    -- Event subscriptions
    HH.Events:On("HEROHELPER_TRIGGER",     function() RB:Show() end)
    HH.Events:On("COMBAT_END",             function() RB:Hide() end)
    HH.Events:On("PLAYER_LOGIN",           function() RB:RefreshIcon() end)
    HH.Events:On("PLAYER_ENTERING_WORLD",  function() RB:RefreshIcon() end)
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
    -- The lock flag is purely visual policy (drag-to-move allowed /
    -- blocked). Nothing cast-related hangs off it; the addon doesn't
    -- cast for you, the reminder is just a visual indicator.
    container:SetMovable(true) -- always movable; OnDragStart gates it
end

-- Refreshes the icon to the correct faction-aware spell texture.
-- Called on init and on PLAYER_LOGIN / PLAYER_ENTERING_WORLD so the
-- icon settles after GetSpellInfo returns a valid value.
function RB:RefreshIcon()
    if HH.State.spellID and container and container.icon then
        local tex = select(3, GetSpellInfo(HH.State.spellID))
        if tex then container.icon:SetTexture(tex) end
    end
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
