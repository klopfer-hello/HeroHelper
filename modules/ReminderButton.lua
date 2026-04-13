--[[
    HeroHelper - Reminder Button Module

    Creates a single SecureActionButtonTemplate that:
      * Is hidden by default
      * Shows only when HEROHELPER_TRIGGER fires (i.e. BL/Hero is castable and
        it is the right moment according to the per-boss config)
      * Casts Heroism / Bloodlust on left-click via a secure macrotext
      * Is movable when unlocked, locked in place when locked
      * Supports per-character position and size (default 40x40)
      * Pulses / glows while visible so the player can't miss it
      * Plays a SharedMedia sound (selectable in the config) on trigger
      * Auto-hides after a successful cast OR when combat ends OR when the
        Sated/Exhaustion debuff is detected on the player

    Implementation notes for TBC Classic Anniversary:
      * We must set the secure attributes outside combat lockdown. The
        button's macrotext is set once in Initialize() and never changes
        during combat, so this is safe.
      * The glow is achieved by animating a texture on OnUpdate — no
        blizzard glow template is needed for TBC.
      * CRITICAL: SecureActionButtonTemplate makes the button a *protected
        frame*, which means calling :Show()/:Hide()/:SetSize()/:SetPoint()
        on it during combat is silently blocked by the WoW secure-code
        restriction. Since the reminder has to appear *in combat*, the
        button is wrapped in a non-protected container Frame, and we do
        NOT toggle Show/Hide OR move the container at all after Initialize:
            * Container is created at the player-saved position.
            * Container is :Show()n exactly once.
            * "Hidden" / "visible" is toggled purely via container:SetAlpha.
        SetAlpha on a plain Frame is always allowed — including in combat —
        and the child button's layout never needs to be recalculated since
        the container never moves or resizes at runtime. A previous attempt
        to park the container off-screen and move it back on Show produced
        a bizarre h=132313 on the protected child, evidently a TBC layout
        bug triggered by the 30000-unit movement during combat lockdown.

        Consequence: the invisible button still captures clicks on its
        saved position. That's tolerable because the macrotext is only
        "armed" when we're about to show the reminder, so clicks on the
        invisible area are no-ops in practice. See ApplyMacrotext.
]]

local ADDON_NAME, HH = ...

HH.ReminderButton = {}
local RB = HH.ReminderButton

-- Non-protected wrapper frame that owns the visible state. See the comment
-- block above for why this wrapper exists.
local container
local button
-- Tracks whether the reminder is logically "visible". We can't rely on
-- container:IsShown() because the container stays permanently Shown.
local visible = false
-- True while TestShow() is displaying a preview reminder. Suppresses the cast
-- macro so clicking / dragging the preview button never actually fires BL/Hero.
local testMode = false

-- ============================================================================
-- Sound registration
-- ============================================================================

local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

-- Known-good built-in sound kit IDs in TBC Classic 2.5.5. Used as reliable
-- fallbacks for PlaySound() when a file path can't be resolved. These are
-- the numeric SoundKitID values from the TBC client.
local SOUNDKIT_RAID_WARNING = 8959
local SOUNDKIT_READY_CHECK  = 8960
local SOUNDKIT_LEVEL_UP     = 888
local SOUNDKIT_AUCTION_OPEN = 6182
local SOUNDKIT_TELL_MESSAGE = 3081

-- Each registered sound is stored as { file = <path>, kit = <soundKitID> }.
-- file is played first via PlaySoundFile; if that fails (willPlay == false,
-- which happens when the .ogg isn't shipped with the client), we fall back
-- to PlaySound(kit). That way the preview / trigger sound always produces
-- *something* audible even if a specific file path is missing on a given
-- client build.
local SOUND_ENTRIES = {
    { key = "HeroHelper: Raid Warning", file = "Sound\\Interface\\RaidWarning.ogg",  kit = SOUNDKIT_RAID_WARNING },
    { key = "HeroHelper: Ready Check",  file = "Sound\\Interface\\ReadyCheck.ogg",   kit = SOUNDKIT_READY_CHECK  },
    { key = "HeroHelper: Level Up",     file = "Sound\\Interface\\LevelUp.ogg",      kit = SOUNDKIT_LEVEL_UP     },
    { key = "HeroHelper: Auction Open", file = "Sound\\Interface\\AuctionWindowOpen.ogg", kit = SOUNDKIT_AUCTION_OPEN },
    { key = "HeroHelper: Tell Message", file = "Sound\\Interface\\iTellMessage.ogg", kit = SOUNDKIT_TELL_MESSAGE },
}

-- key -> entry lookup, so PlaySound can find the kit fallback for whatever
-- sound name is currently saved in settings.
local soundByKey = {}

-- NOTE: LibSharedMedia's lib:Register() rejects any sound whose path doesn't
-- start with "interface" (see LibSharedMedia-3.0.lua around lib:Register).
-- Our built-in sounds live under "Sound\Interface\...", so LSM silently
-- refuses every registration and the sound never appears in LSM:List.
-- We still call :Register so that any other addon inspecting LSM sees an
-- attempt (it's a no-op on failure), but we build the dropdown list and
-- play the sound from our own SOUND_ENTRIES table instead.
local function RegisterSounds()
    for _, entry in ipairs(SOUND_ENTRIES) do
        soundByKey[entry.key] = entry
        if LSM then LSM:Register("sound", entry.key, entry.file) end
    end
end

-- Returns the ordered list of sound keys the user can choose from in the
-- config dropdown. This is *just* our built-in entries — we deliberately do
-- NOT merge in LSM:List("sound"), because other addons (BigWigs, Capping,
-- Details, …) register hundreds of their own sounds into the same shared
-- pool. A real user had 223 entries from other addons in the live client,
-- which produced a dropdown taller than the screen that couldn't be used.
-- If someone wants an exotic sound they can register it via LSM and we'll
-- still play it via PlaySoundEntry — but the picker is kept small and
-- curated on purpose.
function RB:GetSoundList()
    local list = {}
    for _, entry in ipairs(SOUND_ENTRIES) do
        table.insert(list, entry.key)
    end
    return list
end

-- ============================================================================
-- Button creation
-- ============================================================================

function RB:Initialize()
    if not HH.State.isShaman then return end

    RegisterSounds()
    self:CreateButton()
    self:ApplyPosition()
    self:ApplySize()
    self:ApplyLock()
    self:ApplyMacrotext()

    -- Event subscriptions
    HH.Events:On("HEROHELPER_TRIGGER", function() RB:Show() end)
    HH.Events:On("COMBAT_END",          function() RB:Hide() end)
    HH.Events:On("PLAYER_LOGIN",        function() RB:ApplyMacrotext() end)
    HH.Events:On("PLAYER_ENTERING_WORLD", function() RB:ApplyMacrotext() end)
    HH.Events:On("PLAYER_AURA_CHANGED", function()
        if HH.chardb.settings.hideOnDebuff and HH:HasExhaustionDebuff() then
            RB:Hide()
        end
    end)
    HH.Events:On("COOLDOWN_CHANGED", function()
        -- If BL/Hero actually went on cooldown (i.e. we successfully cast),
        -- schedule a fade-out. Use the logical `visible` flag — the
        -- container stays permanently :Show()'d so IsShown would always be
        -- true and this check would misfire on every cooldown change.
        if container and visible and HH:IsSpellOnCooldown() then
            local fade = HH.chardb.settings.postCastFade or 2
            C_Timer.After(fade, function() RB:Hide() end)
        end
    end)
end

function RB:CreateButton()
    if button then return end

    -- Non-protected container — owns alpha/position so we can touch it
    -- during combat without tripping the protected-frame rules. The
    -- container is Shown once at Initialize and *never* hidden; see the
    -- file header for the full rationale. Start it parked off-screen with
    -- zero alpha so it's logically "hidden" from the player's POV.
    container = CreateFrame("Frame", "HeroHelperReminderContainer", UIParent)
    container:SetFrameStrata("HIGH")
    container:SetFrameLevel(100)
    container:SetClampedToScreen(true)
    container:SetMovable(true)
    -- Initial size MUST be set before the button is anchored to the
    -- container so the child button's layout resolves correctly.
    container:SetSize(40, 40)
    -- Container is placed at the player-saved position immediately and
    -- NEVER moved again at runtime. Hide/show toggles only alpha — see
    -- the file header for the full rationale (TBC layout bug on moves).
    local s = HH.chardb and HH.chardb.settings and HH.chardb.settings.button
    container:ClearAllPoints()
    container:SetPoint(
        (s and s.point)         or "CENTER",
        UIParent,
        (s and s.relativePoint) or "CENTER",
        (s and s.x)             or 0,
        (s and s.y)             or 0
    )
    container:SetAlpha(0) -- start logically hidden
    container:Show()

    button = CreateFrame("Button", "HeroHelperReminderButton", container, "SecureActionButtonTemplate")
    -- SINGLE center anchor + explicit SetSize. We originally used 2-point
    -- TOPLEFT/BOTTOMRIGHT anchors to make the button track container size,
    -- but TBC's layout evaluator refused to propagate container's height
    -- through those anchors on a protected button — we observed h=0 at
    -- init and h=132313 after a position change. A single CENTER anchor
    -- with an explicit SetSize gives the button concrete, deterministic
    -- dimensions that don't depend on anchor resolution; ApplySize keeps
    -- button and container in lockstep when the player changes the size.
    button:ClearAllPoints()
    button:SetPoint("CENTER", container, "CENTER", 0, 0)
    button:SetSize(40, 40)
    button:SetFrameStrata("HIGH")
    button:SetFrameLevel(101)
    button:RegisterForClicks("AnyUp", "AnyDown")
    button:RegisterForDrag("LeftButton")
    button:EnableMouse(true)

    -- Icon — solid spell icon, anchored to the button. TexCoord cropping
    -- trims the standard 8% Blizzard icon border so the artwork reaches the
    -- edges of the button.
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints(button)
    local spellID = HH.State.spellID or HH.SPELL_HEROISM
    local spellTexture = select(3, GetSpellInfo(spellID)) or "Interface\\Icons\\Spell_Nature_Bloodlust"
    icon:SetTexture(spellTexture)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    button.icon = icon

    -- Pulse overlay. We animate its *alpha* on OnUpdate (not scale) so that
    -- the glow stays perfectly centered on the button at every size. The
    -- texture is the guaranteed-present action-button border, overshooting
    -- the button on all four sides via symmetric SetPoint offsets (applied
    -- in ApplySize). Alpha-only animation means the alignment never drifts.
    local pulse = button:CreateTexture(nil, "OVERLAY", nil, 1)
    pulse:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    pulse:SetBlendMode("ADD")
    pulse:SetVertexColor(1, 0.55, 0.0, 1)
    button.pulse = pulse

    -- Thin orange static border so the button is visible even at the
    -- low-alpha end of the pulse animation. Four 1 px edge textures give us
    -- a pixel-perfect frame with zero scaling artifacts.
    local function edge(point1, point2, horiz)
        local t = button:CreateTexture(nil, "OVERLAY", nil, 2)
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

    -- Label (boss name beneath)
    local label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    label:SetPoint("BOTTOM", button, "TOP", 0, 4)
    label:SetTextColor(1, 0.82, 0)
    button.label = label

    -- Secure macrotext: cast Heroism or Bloodlust at the player
    button:SetAttribute("type1", "macro")

    -- Drag handlers (only active when unlocked). We move the non-protected
    -- container so saved position/size edits never touch the secure button.
    button:SetScript("OnDragStart", function()
        if not HH.chardb.settings.button.locked then
            container:StartMoving()
        end
    end)
    button:SetScript("OnDragStop", function()
        container:StopMovingOrSizing()
        local point, _, relativePoint, x, y = container:GetPoint()
        HH.chardb.settings.button.point         = point
        HH.chardb.settings.button.relativePoint = relativePoint
        HH.chardb.settings.button.x             = x
        HH.chardb.settings.button.y             = y
    end)

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("|cFFFF7D1AHeroHelper|r", 1, 1, 1)
        if HH.State.spellName then
            GameTooltip:AddLine("Click to cast " .. HH.State.spellName, 1, 1, 1)
        else
            GameTooltip:AddLine("No Heroism/Bloodlust known", 1, 0.3, 0.3)
        end
        if HH.State.currentBossName then
            GameTooltip:AddLine("Trigger: " .. HH.State.currentBossName, 0.7, 0.7, 0.7)
        end
        if not HH.chardb.settings.button.locked then
            GameTooltip:AddLine("Drag to move", 0.5, 0.5, 0.5)
        end
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Pulse animation — alpha-only modulation so the glow stays perfectly
    -- centered on the button regardless of size. Tuned for high visibility:
    -- the alpha never drops below 0.55 so the glow is always present, and
    -- peaks at 1.0 for an aggressive flash. Cycle speed 6 rad/s = ~1.05s
    -- per pulse, fast enough to grab the eye without flickering.
    local elapsed = 0
    button:SetScript("OnUpdate", function(self, e)
        if not self.pulse then return end
        elapsed = elapsed + e
        local a = 0.55 + 0.45 * (1 + math.sin(elapsed * 6)) * 0.5
        self.pulse:SetAlpha(a)
    end)
end

-- ============================================================================
-- Apply config
-- ============================================================================

-- Move the container to the player-configured coordinates. Called from
-- Initialize() to set the initial position, and from the drag OnDragStop
-- when the player moves the reminder. Safe to call in combat (SetPoint on
-- a non-protected Frame is allowed).
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
    -- Button is CENTER-anchored + explicitly sized (see CreateButton). We
    -- must also update its size here so it stays in lockstep with the
    -- container. SetSize on a protected frame is restricted in combat, so
    -- gate it — the config slider is the only path that calls ApplySize
    -- at runtime, and sliders can only be moved outside combat anyway.
    if button and not InCombatLockdown() then
        button:SetSize(size, size)
    end

    -- Anchor the pulse to the button's four corners with a symmetric
    -- outward offset (50% of the button size on each side, up from the
    -- previous 30%). The wider halo makes the reminder unmissable in a
    -- busy raid frame layout. Symmetric offsets keep the glow centered
    -- at every size with no dependency on the texture's aspect ratio.
    if button.pulse then
        local overshoot = math.floor(size * 0.50 + 0.5)
        button.pulse:ClearAllPoints()
        button.pulse:SetPoint("TOPLEFT",     button, "TOPLEFT",     -overshoot,  overshoot)
        button.pulse:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT",  overshoot, -overshoot)
    end
end

function RB:ApplyLock()
    if not container then return end
    -- In test mode the button is always draggable regardless of the saved
    -- lock state, so ApplyLock only touches the secure macrotext. The
    -- effective move/drag state is restored when test mode is disabled.
    if testMode then
        self:ApplyMacrotext()
        return
    end
    local locked = HH.chardb.settings.button.locked
    -- SetMovable lives on the container — that's what StartMoving acts on.
    container:SetMovable(not locked)
    if locked then
        button:RegisterForDrag() -- unregister drag
    else
        button:RegisterForDrag("LeftButton")
    end
    -- Lock state changes what the button does on click (real cast vs no-op),
    -- so the secure macrotext has to be refreshed.
    self:ApplyMacrotext()
end

-- Set the secure macrotext for the cast. Must be called outside of combat.
--
-- The button is **only** armed to cast when it is locked in place and not in
-- test mode. When unlocked, clicks must be no-ops so the user can freely
-- left-click-drag the button without accidentally burning BL/Hero. The same
-- applies to TestShow(): a preview must never fire the spell.
function RB:ApplyMacrotext()
    if not button then return end
    if InCombatLockdown() then return end

    local locked = HH.chardb.settings.button.locked
    local armed  = locked and not testMode and HH.State.spellName ~= nil

    local text
    if armed then
        local override = HH.chardb.settings.macrotext
        if override and override ~= "" then
            text = override
        else
            text = "/cast [@player] " .. HH.State.spellName
        end
    else
        -- Empty macrotext = click does nothing. Using "" rather than nil so
        -- the attribute is explicitly cleared.
        text = ""
    end
    button:SetAttribute("macrotext1", text)

    -- Refresh icon as well (faction may have been unknown at first init)
    if HH.State.spellID then
        local tex = select(3, GetSpellInfo(HH.State.spellID))
        if tex and button.icon then button.icon:SetTexture(tex) end
    end
end

-- ============================================================================
-- Show / hide
-- ============================================================================

function RB:Show()
    if not container then return end
    -- If a real trigger fires while the user is still in test mode (e.g.
    -- they forgot to disable it and pulled), exit test mode first so the
    -- button is armed for the real fight.
    if testMode then self:SetTestMode(false) end
    button.label:SetText(HH.State.currentBossName or "HeroHelper")
    -- "Show" is a pure alpha toggle. The container stays at its saved
    -- position from Initialize; we never move it at runtime.
    visible = true
    container:SetAlpha(1)
    self:PlaySound()
end

function RB:Hide()
    if not container then return end
    -- Test mode is sticky — don't let combat end / debuff / cast auto-hide
    -- kick us out of it. Only explicit SetTestMode(false) can exit test.
    if testMode then return end
    visible = false
    container:SetAlpha(0)
end

function RB:IsVisible()
    return visible or testMode
end

-- ============================================================================
-- Test mode (toggleable)
-- ============================================================================
--
-- Test mode is a *persistent* toggle, not a timed preview. When enabled:
--   * the reminder button is forced visible
--   * it is force-unlocked so the user can drag it into position
--   * its secure macrotext is cleared to "" so clicks / drags never cast
--
-- The user turns it off again via the same toggle in the config panel,
-- the /hh test slash command, or by pressing the bind key. Disabling test
-- mode restores the saved lock state and the real cast macro, and hides
-- the button.

function RB:IsTestMode()
    return testMode
end

function RB:SetTestMode(enable)
    if not container then return end
    if InCombatLockdown() then
        HH:Print("Cannot change test mode while in combat.", HH.Colors.warning)
        return
    end

    if enable then
        testMode = true
        -- Force drag enabled regardless of saved lock. Dragging moves the
        -- container, so SetMovable lives there.
        container:SetMovable(true)
        button:RegisterForDrag("LeftButton")
        -- ApplyMacrotext sees testMode == true and clears macrotext1 to ""
        self:ApplyMacrotext()
        button.label:SetText("TEST")
        container:SetAlpha(1)
        self:PlaySound()
    else
        testMode = false
        -- Restore the saved lock + the real cast macro
        self:ApplyLock()
        if not visible then
            container:SetAlpha(0)
        end
    end
end

function RB:ToggleTestMode()
    self:SetTestMode(not testMode)
end

-- Back-compat alias. /hh test and the keybinding used to call :TestShow(),
-- keep that name working as a toggle.
function RB:TestShow()
    self:ToggleTestMode()
end

-- Core sound playback. Returns true if *anything* was queued to play.
--
-- PlaySoundFile is tried first so the user hears whatever LSM media they
-- selected (including custom SharedMedia from other addons). If the file
-- can't be resolved by the client (willPlay == false, which happens in
-- TBC for .ogg paths that don't ship with 2.5.5) we fall back to the
-- numeric SoundKit ID associated with the same entry. Only if *both*
-- fail do we fall back to a global default. This chain is the reason
-- the preview used to look broken — the old code silently assumed
-- PlaySoundFile always succeeds.
local function PlaySoundEntry(key)
    -- 1) Try the exact LSM file the user picked.
    if LSM and key then
        local file = LSM:Fetch("sound", key, true)
        if file then
            local willPlay = PlaySoundFile(file, "Master")
            if willPlay then return true end
        end
    end

    -- 2) Fall back to the SoundKit ID bundled with the same entry.
    local entry = key and soundByKey[key]
    if entry and entry.kit then
        local willPlay = PlaySound(entry.kit, "Master")
        if willPlay then return true end
    end

    -- 3) Last-resort global fallback: raid warning is universally present.
    PlaySound(SOUNDKIT_RAID_WARNING, "Master")
    return true
end

-- Fired on HEROHELPER_TRIGGER. Respects the user's "Play sound on trigger"
-- toggle — if they've disabled sounds, the reminder still shows but stays
-- silent.
function RB:PlaySound()
    if not HH.chardb.settings.soundEnabled then return end
    PlaySoundEntry(HH.chardb.settings.sound)
end

-- Fired by the "Preview sound" button in the config panel. Intentionally
-- bypasses the soundEnabled flag — the whole point of the preview is to
-- let the user audition a sound before deciding whether to enable it.
function RB:PreviewSound()
    PlaySoundEntry(HH.chardb.settings.sound)
end
