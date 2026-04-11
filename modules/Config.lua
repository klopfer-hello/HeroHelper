--[[
    HeroHelper - Config Module

    Settings panel accessible via /hh or the minimap button. Two tabs:

        General  - enable/disable, minimap toggle, sound selection, button
                   size slider, lock toggle, button reset
        Bosses   - scrollable list grouped by raid, each row shows:
                       [boss name]  [trigger type dropdown]  [value field]
                   Changes are written into HH.chardb.bosses[id].

    The styling mirrors FishingKit's Config.lua (flat dark backdrop, thin
    1-px borders, muted section headers, compact layout). This is a
    self-contained implementation — no Ace or Blizzard interface options API
    is used, matching FishingKit's conventions.
]]

local ADDON_NAME, HH = ...

HH.Config = {}
local Config = HH.Config

local LSM   = LibStub and LibStub("LibSharedMedia-3.0", true)
-- LibUIDropDownMenu-4.0 is a drop-in replacement for Blizzard's
-- UIDropDownMenuTemplate. Required in TBC Classic 2.5.5 because the
-- native UIDropDownMenuTemplate from the stock client is tainted / buggy:
-- items display but clicks on them don't register, making it impossible
-- to change the selection. Every major TBC addon with working dropdowns
-- (LoonBestInSlot, Questie, WeakAuras, RXPGuides, ProEnchanters, …)
-- ships this same lib for the same reason.
local LibDD = LibStub and LibStub("LibUIDropDownMenu-4.0", true)

-- UI constants
local FRAME_WIDTH  = 460
local FRAME_HEIGHT = 560
local PADDING      = 14
local ROW_HEIGHT   = 26

-- Design palette
local D = {
    bg      = {0.04, 0.04, 0.06},  bgA  = 0.93,
    border  = {0.18, 0.18, 0.23},  borA = 0.80,
    divider = {0.14, 0.14, 0.18},  divA = 0.90,
    accent  = {1.00, 0.49, 0.10},           -- Heroism/BL orange
    label   = {0.40, 0.40, 0.45},
    value   = {0.82, 0.84, 0.88},
    success = {0.26, 0.76, 0.42},
}

-- ============================================================================
-- Generic widget helpers (mirrors FishingKit's AddThinBorder / buttons)
-- ============================================================================

local function AddThinBorder(f, r, g, b, a)
    local t  = f:CreateTexture(nil,"OVERLAY"); t:SetPoint("TOPLEFT");     t:SetPoint("TOPRIGHT");    t:SetHeight(1); t:SetColorTexture(r,g,b,a)
    local bb = f:CreateTexture(nil,"OVERLAY"); bb:SetPoint("BOTTOMLEFT"); bb:SetPoint("BOTTOMRIGHT"); bb:SetHeight(1); bb:SetColorTexture(r,g,b,a)
    local l  = f:CreateTexture(nil,"OVERLAY"); l:SetPoint("TOPLEFT");     l:SetPoint("BOTTOMLEFT");  l:SetWidth(1);  l:SetColorTexture(r,g,b,a)
    local rr = f:CreateTexture(nil,"OVERLAY"); rr:SetPoint("TOPRIGHT");   rr:SetPoint("BOTTOMRIGHT"); rr:SetWidth(1); rr:SetColorTexture(r,g,b,a)
end

local function MakeFlatButton(parent, text, width, height)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(width or 110, height or 22)

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.10, 0.10, 0.13, 1)
    btn.bg = bg

    AddThinBorder(btn, D.border[1], D.border[2], D.border[3], D.borA)

    local lbl = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetAllPoints()
    lbl:SetJustifyH("CENTER")
    lbl:SetText(text)
    lbl:SetTextColor(D.value[1], D.value[2], D.value[3])
    btn.label = lbl

    btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    btn:GetHighlightTexture():SetBlendMode("ADD")

    return btn
end

-- Hand-rolled flat checkbox (14x14 square + accent fill when checked).
-- Returns a container Frame with :SetChecked(bool), :GetChecked(), and
-- :HookClick(fn) methods. Matches the FishingKit visual style.
local function MakeCheckbox(parent, label)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(260, 22)

    local box = CreateFrame("Button", nil, container)
    box:SetSize(14, 14)
    box:SetPoint("LEFT", container, "LEFT", 0, 0)

    local boxBg = box:CreateTexture(nil, "BACKGROUND")
    boxBg:SetAllPoints()
    boxBg:SetColorTexture(0.07, 0.07, 0.09, 1)
    AddThinBorder(box, D.border[1], D.border[2], D.border[3], 0.85)

    local fill = box:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT",     2, -2)
    fill:SetPoint("BOTTOMRIGHT", -2, 2)
    fill:SetColorTexture(D.accent[1], D.accent[2], D.accent[3], 1)
    fill:Hide()

    box:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    box:GetHighlightTexture():SetBlendMode("ADD")

    local txt = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    txt:SetPoint("LEFT", box, "RIGHT", 8, 0)
    txt:SetText(label)
    txt:SetTextColor(D.value[1], D.value[2], D.value[3])

    local checked = false
    function container:SetChecked(v)
        checked = v and true or false
        if checked then fill:Show() else fill:Hide() end
    end
    function container:GetChecked() return checked end
    function container:HookClick(fn)
        box:SetScript("OnClick", function()
            container:SetChecked(not checked)
            if fn then fn(checked) end
        end)
    end

    return container
end

-- Slider using a simple manual implementation (native Slider is unreliable in
-- TBC Anniversary — FishingKit reports the same and uses a hand-rolled one).
local function MakeSlider(parent, label, min, max, step, initial, onChange)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(220, 26)

    local lbl = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
    lbl:SetText(label)
    lbl:SetTextColor(D.label[1], D.label[2], D.label[3])

    local value = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    value:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, 0)
    value:SetText(tostring(initial))
    value:SetTextColor(D.value[1], D.value[2], D.value[3])

    local track = CreateFrame("Frame", nil, container)
    track:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 0, 2)
    track:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 2)
    track:SetHeight(6)
    local trackBg = track:CreateTexture(nil, "BACKGROUND")
    trackBg:SetAllPoints()
    trackBg:SetColorTexture(0.10, 0.10, 0.13, 1)

    local fill = track:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("LEFT", track, "LEFT")
    fill:SetHeight(6)
    fill:SetColorTexture(D.accent[1], D.accent[2], D.accent[3], 0.9)

    -- Redraw the fill bar from the current container.value. Split out so
    -- OnSizeChanged can rerun it after the caller resizes the slider (the
    -- track width is only known once the slider has been laid out by its
    -- parent, so we cannot bake the fill width in at construction time).
    local function RedrawFill()
        local v = container.value
        if not v then return end
        local pct = (v - min) / (max - min)
        local width = track:GetWidth() * pct
        if width < 1 then width = 1 end
        fill:SetWidth(width)
    end

    local function SetValue(v, fireChange)
        v = math.max(min, math.min(max, v))
        v = math.floor(v / step + 0.5) * step
        container.value = v
        value:SetText(tostring(v))
        RedrawFill()
        if fireChange and onChange then onChange(v) end
    end

    -- Rerun layout when the track width changes (caller usually calls
    -- :SetWidth after MakeSlider returns).
    track:SetScript("OnSizeChanged", RedrawFill)

    track:EnableMouse(true)
    track:SetScript("OnMouseDown", function(self)
        self:SetScript("OnUpdate", function(self)
            local x = GetCursorPosition() / self:GetEffectiveScale()
            local left = self:GetLeft()
            if left then
                local pct = (x - left) / self:GetWidth()
                pct = math.max(0, math.min(1, pct))
                SetValue(min + pct * (max - min), true)
            end
            if not IsMouseButtonDown("LeftButton") then
                self:SetScript("OnUpdate", nil)
            end
        end)
    end)

    container.SetValue = SetValue
    -- Set the initial value without firing onChange, so opening the config
    -- panel doesn't overwrite the saved value with its own current value.
    SetValue(initial, false)
    return container
end

-- Dropdown built on LibUIDropDownMenu-4.0 (see the LibDD require at the top
-- of this file for *why* we can't use the native template). LibDD mirrors
-- the Blizzard API with lib:-prefixed methods, so the call sites look
-- almost identical to the old UIDropDownMenu version — the important
-- difference is that clicks on menu items actually register.
--
-- Each dropdown needs a globally unique frame name, so we generate one per
-- call via a monotonic counter.
-- Force-clear every button on the shared list frame at `level` and reset
-- its numButtons counter. LibDD's UIDropDownMenu_InitializeHelper is
-- *supposed* to do this before an init function runs, but in practice
-- (observed live: sound dropdown opened with its own 5 items plus 4 stale
-- raid entries leaking through as buttons 6-9) the clear does not cover
-- buttons that belonged to a previously-initialized dropdown. Running
-- this at the top of every init closure guarantees a clean slate.
local function ForceClearDropDownList(level)
    level = level or 1
    local listFrameName = "L_DropDownList" .. level
    local listFrame = _G[listFrameName]
    if not listFrame then return end
    -- L_UIDROPDOWNMENU_MAXBUTTONS is the dynamic high-water mark of
    -- buttons ever created; blasting through that range covers every
    -- button any dropdown has ever added at this level.
    local maxButtons = _G.L_UIDROPDOWNMENU_MAXBUTTONS or 32
    for j = 1, maxButtons do
        local btn = _G[listFrameName .. "Button" .. j]
        if btn then btn:Hide() end
    end
    listFrame.numButtons = 0
    listFrame.maxWidth   = 0
end

local dropdownCounter = 0
-- `debugTag` is accepted but unused — it was the hook for loud per-dropdown
-- debug prints during the sound-dropdown investigation; kept in the
-- signature so call sites don't need touching if we ever re-enable it.
local function MakeDropdown(parent, width, items, onSelect, initialText, debugTag)
    dropdownCounter = dropdownCounter + 1
    local name = "HeroHelperDropdown" .. dropdownCounter

    -- Fallback: if LibDD failed to load (shouldn't happen because we embed
    -- it, but defensive anyway), fall back to the native template so the
    -- addon at least loads without errors.
    local dd
    if LibDD then
        dd = LibDD:Create_UIDropDownMenu(name, parent)
        LibDD:UIDropDownMenu_SetWidth(dd, width)
        LibDD:UIDropDownMenu_SetText(dd, initialText or "")

        LibDD:UIDropDownMenu_Initialize(dd, function(self, level)
            ForceClearDropDownList(level or 1)
            for _, entry in ipairs(items) do
                local info = LibDD:UIDropDownMenu_CreateInfo()
                info.text         = entry.label
                info.value        = entry.value
                info.notCheckable = true
                info.func = function()
                    LibDD:UIDropDownMenu_SetText(dd, entry.label)
                    if onSelect then onSelect(entry.value, entry.label) end
                end
                LibDD:UIDropDownMenu_AddButton(info, level)
            end
        end)
    else
        dd = CreateFrame("Frame", name, parent, "UIDropDownMenuTemplate")
        UIDropDownMenu_SetWidth(dd, width)
        UIDropDownMenu_SetText(dd, initialText or "")
        UIDropDownMenu_Initialize(dd, function(self, level)
            ForceClearDropDownList(level or 1)
            for _, entry in ipairs(items) do
                local info = UIDropDownMenu_CreateInfo()
                info.text         = entry.label
                info.value        = entry.value
                info.notCheckable = true
                info.func = function()
                    UIDropDownMenu_SetText(dd, entry.label)
                    if onSelect then onSelect(entry.value, entry.label) end
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end)
    end

    -- Expose the SetText method on the frame itself so callers (like the
    -- sound-dropdown OnShow refresh) can update the displayed text without
    -- needing to know which underlying API was used.
    function dd:RefreshText(text)
        if LibDD then
            LibDD:UIDropDownMenu_SetText(self, text or "")
        else
            UIDropDownMenu_SetText(self, text or "")
        end
    end

    return dd
end

-- ============================================================================
-- Frame creation
-- ============================================================================

local configState = {
    frame   = nil,
    visible = false,
    tab     = "general",
}

function Config:Initialize()
    self:CreateFrame()
end

function Config:CreateFrame()
    if configState.frame then return end

    local frame = CreateFrame("Frame", "HeroHelperConfigFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:Hide()

    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

    -- ESC closes the panel. WoW's UIParent handles any frame listed in the
    -- global UISpecialFrames table — it calls :Hide() on each when the player
    -- presses Escape and no higher-priority frame captures the key.
    table.insert(UISpecialFrames, "HeroHelperConfigFrame")

    -- Keep our visibility flag in sync when the frame is hidden via ESC or
    -- via any other external mechanism.
    frame:SetScript("OnHide", function() configState.visible = false end)
    frame:SetScript("OnShow", function() configState.visible = true end)

    if frame.SetBackdrop then
        frame:SetBackdrop({
            bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 8,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        frame:SetBackdropColor(D.bg[1], D.bg[2], D.bg[3], D.bgA)
        frame:SetBackdropBorderColor(D.border[1], D.border[2], D.border[3], D.borA)
    else
        local bg = frame:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(D.bg[1], D.bg[2], D.bg[3], D.bgA)
    end

    -- Title
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -PADDING)
    title:SetText("|cFFFF7D1AHeroHelper|r  |cFF66666BSettings|r")

    -- Close button
    local closeBtn = CreateFrame("Button", nil, frame)
    closeBtn:SetSize(20, 20)
    closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PADDING + 4, -PADDING + 2)
    local closeX = closeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    closeX:SetAllPoints()
    closeX:SetJustifyH("CENTER")
    closeX:SetText("|cFF66666B×|r")
    closeBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    closeBtn:GetHighlightTexture():SetBlendMode("ADD")
    closeBtn:SetScript("OnClick", function() Config:Hide() end)

    -- Title divider
    local titleDiv = frame:CreateTexture(nil, "ARTWORK")
    titleDiv:SetHeight(1)
    titleDiv:SetPoint("TOPLEFT",  frame, "TOPLEFT",  PADDING, -(PADDING + 20))
    titleDiv:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PADDING, -(PADDING + 20))
    titleDiv:SetColorTexture(D.divider[1], D.divider[2], D.divider[3], D.divA)

    -- Tabs
    local tabGeneral = MakeFlatButton(frame, "General", 80, 22)
    tabGeneral:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -(PADDING + 26))
    tabGeneral:SetScript("OnClick", function() Config:SwitchTab("general") end)

    local tabBosses = MakeFlatButton(frame, "Bosses", 80, 22)
    tabBosses:SetPoint("LEFT", tabGeneral, "RIGHT", 4, 0)
    tabBosses:SetScript("OnClick", function() Config:SwitchTab("bosses") end)

    frame.tabGeneral = tabGeneral
    frame.tabBosses  = tabBosses

    -- Content panels.
    --
    -- configState.frame has to be set *before* BuildBossesTab runs — that
    -- function calls RefreshBossList at the end of setup, and RefreshBossList
    -- reads the panel via configState.frame.bossPanel. Without this ordering
    -- the initial refresh no-ops silently and the Bosses tab appears empty
    -- until the player clicks the raid dropdown once.
    configState.frame = frame

    local generalPanel = CreateFrame("Frame", nil, frame)
    generalPanel:SetPoint("TOPLEFT",  frame, "TOPLEFT",  PADDING, -(PADDING + 54))
    generalPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PADDING, PADDING)
    frame.generalPanel = generalPanel
    self:BuildGeneralTab(generalPanel)

    local bossPanel = CreateFrame("Frame", nil, frame)
    bossPanel:SetPoint("TOPLEFT",  frame, "TOPLEFT",  PADDING, -(PADDING + 54))
    bossPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PADDING, PADDING)
    bossPanel:Hide()
    frame.bossPanel = bossPanel
    self:BuildBossesTab(bossPanel)

    self:SwitchTab("general")
end

function Config:SwitchTab(tab)
    configState.tab = tab
    if not configState.frame then return end
    local f = configState.frame
    if tab == "general" then
        f.generalPanel:Show()
        f.bossPanel:Hide()
        f.tabGeneral.bg:SetColorTexture(D.accent[1]*0.3, D.accent[2]*0.3, D.accent[3]*0.3, 1)
        f.tabBosses.bg:SetColorTexture(0.10, 0.10, 0.13, 1)
    else
        f.generalPanel:Hide()
        f.bossPanel:Show()
        f.tabGeneral.bg:SetColorTexture(0.10, 0.10, 0.13, 1)
        f.tabBosses.bg:SetColorTexture(D.accent[1]*0.3, D.accent[2]*0.3, D.accent[3]*0.3, 1)
    end
end

-- ============================================================================
-- General tab
-- ============================================================================

function Config:BuildGeneralTab(panel)
    local y = 0

    local function SectionHeader(text)
        local lbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, y)
        lbl:SetText(text)
        lbl:SetTextColor(D.label[1], D.label[2], D.label[3])

        local line = panel:CreateTexture(nil, "ARTWORK")
        line:SetHeight(1)
        line:SetPoint("TOPLEFT",  panel, "TOPLEFT",  0, y - 14)
        line:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, y - 14)
        line:SetColorTexture(D.divider[1], D.divider[2], D.divider[3], D.divA)
        y = y - 22
    end

    SectionHeader("ADDON")

    -- Enabled checkbox
    local cbEnabled = MakeCheckbox(panel, "Enable HeroHelper")
    cbEnabled:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, y)
    cbEnabled:HookClick(function(checked) HH.db.settings.enabled = checked end)
    y = y - ROW_HEIGHT

    local cbMinimap = MakeCheckbox(panel, "Show minimap button")
    cbMinimap:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, y)
    cbMinimap:HookClick(function(checked)
        if checked then HH.Minimap:Show() else HH.Minimap:Hide() end
    end)
    y = y - ROW_HEIGHT

    -- Master toggle for 5-man dungeon boss alerts. When on, every TBC
    -- dungeon boss fires a "pull" trigger; see Database.lua dungeon block
    -- and the isDungeon gate in GetTriggerConfig.
    local cbDungeons = MakeCheckbox(panel, "Alert for dungeon bosses (5-man, on pull)")
    cbDungeons:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, y)
    cbDungeons:HookClick(function(checked)
        HH.db.settings.dungeonPullAlerts = checked
    end)
    y = y - ROW_HEIGHT

    y = y - 8
    SectionHeader("REMINDER BUTTON")

    local cbLocked = MakeCheckbox(panel, "Lock reminder button in place")
    cbLocked:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, y)
    cbLocked:HookClick(function(checked)
        HH.chardb.settings.button.locked = checked
        if HH.ReminderButton then HH.ReminderButton:ApplyLock() end
    end)
    y = y - ROW_HEIGHT

    local sizeSlider = MakeSlider(panel, "Button size", 24, 96, 2, HH.chardb.settings.button.size or 40, function(v)
        HH.chardb.settings.button.size = v
        if HH.ReminderButton then HH.ReminderButton:ApplySize() end
    end)
    sizeSlider:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, y)
    sizeSlider:SetWidth(FRAME_WIDTH - 2*PADDING - 10)
    y = y - (ROW_HEIGHT + 4)

    local resetBtn = MakeFlatButton(panel, "Reset position", 120, 22)
    resetBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, y)
    resetBtn:SetScript("OnClick", function()
        local s = HH.chardb.settings.button
        s.point         = "CENTER"
        s.relativePoint = "CENTER"
        s.x             = 0
        s.y             = 0
        if HH.ReminderButton then HH.ReminderButton:ApplyPosition() end
        HH:Print("Reminder button position reset.", HH.Colors.success)
    end)
    y = y - ROW_HEIGHT

    -- Persistent test-mode toggle. While enabled the reminder button is
    -- forced visible, force-unlocked, and completely disarmed (clicks and
    -- drags never fire the real cast). Uncheck when you're done positioning.
    local cbTest = MakeCheckbox(panel, "Test mode (show button for positioning)")
    cbTest:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, y)
    cbTest:HookClick(function(checked)
        if HH.ReminderButton then
            HH.ReminderButton:SetTestMode(checked)
            -- If SetTestMode refused (in combat), revert the checkbox visual
            -- so it reflects reality.
            cbTest:SetChecked(HH.ReminderButton:IsTestMode())
        end
    end)
    y = y - ROW_HEIGHT

    y = y - 8
    SectionHeader("SOUND")

    local cbSoundEnabled = MakeCheckbox(panel, "Play sound on trigger")
    cbSoundEnabled:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, y)
    cbSoundEnabled:HookClick(function(checked)
        HH.chardb.settings.soundEnabled = checked
    end)
    y = y - ROW_HEIGHT

    -- Inline sound picker.
    --
    -- We deliberately do NOT use a UIDropDownMenu here — LibUIDropDownMenu's
    -- shared list frame leaked buttons from previously-initialized dropdowns
    -- into the sound menu on the live client (5 sounds + 4 stale raid names,
    -- see the git log for the long debugging story). With only ~5 built-in
    -- sounds to pick from, showing all rows inline is both simpler and a
    -- better UX: you can see every option at once, there's no menu-open
    -- animation, and each row has its own 🔊 preview button. Pattern adapted
    -- from NovaWorldBuffs' LSM30_Sound widget (the check / text / speaker
    -- row layout) but built with plain CreateFrame so we don't depend on
    -- AceGUI.
    local soundRows   = {}
    local ROW_H       = 20
    local ROW_INDENT  = 8

    local function RefreshSoundRowSelection()
        local saved = HH.chardb.settings.sound
        for _, row in ipairs(soundRows) do
            if row.key == saved then
                row.check:Show()
                row.text:SetTextColor(D.accent[1], D.accent[2], D.accent[3])
            else
                row.check:Hide()
                row.text:SetTextColor(D.value[1], D.value[2], D.value[3])
            end
        end
    end

    local soundList = (HH.ReminderButton and HH.ReminderButton:GetSoundList())
        or { "HeroHelper: Raid Warning" }
    for _, key in ipairs(soundList) do
        local row = CreateFrame("Button", nil, panel)
        row:SetSize(FRAME_WIDTH - 2*PADDING - 20, ROW_H)
        row:SetPoint("TOPLEFT", panel, "TOPLEFT", ROW_INDENT, y)

        -- Hover highlight (whole row). Clicking the row anywhere outside
        -- the speaker button selects this sound.
        local hi = row:CreateTexture(nil, "HIGHLIGHT")
        hi:SetAllPoints()
        hi:SetColorTexture(D.accent[1], D.accent[2], D.accent[3], 0.15)

        -- Left-edge check mark, shown only on the currently selected row.
        local check = row:CreateTexture(nil, "ARTWORK")
        check:SetSize(12, 12)
        check:SetPoint("LEFT", row, "LEFT", 2, 0)
        check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
        check:Hide()
        row.check = check

        -- Right-edge speaker button: previews the sound without changing
        -- the selection. Handy for auditioning alternatives before you
        -- commit to one.
        local speaker = CreateFrame("Button", nil, row)
        speaker:SetSize(16, 16)
        speaker:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        local spkTex = speaker:CreateTexture(nil, "ARTWORK")
        spkTex:SetAllPoints()
        spkTex:SetTexture("Interface\\Common\\VoiceChat-Speaker")
        speaker:SetHighlightTexture("Interface\\Common\\VoiceChat-On")
        speaker:SetScript("OnClick", function()
            -- Temporarily swap the saved sound so PreviewSound plays this
            -- specific row's sound, then restore. PreviewSound always reads
            -- HH.chardb.settings.sound, so this is the simplest way to
            -- audition a *different* sound without selecting it.
            local prev = HH.chardb.settings.sound
            HH.chardb.settings.sound = key
            if HH.ReminderButton then HH.ReminderButton:PreviewSound() end
            HH.chardb.settings.sound = prev
        end)

        local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint("LEFT", check, "RIGHT", 6, 0)
        text:SetPoint("RIGHT", speaker, "LEFT", -6, 0)
        text:SetJustifyH("LEFT")
        text:SetText(key)
        text:SetTextColor(D.value[1], D.value[2], D.value[3])
        row.text = text
        row.key  = key

        row:SetScript("OnClick", function()
            HH.chardb.settings.sound = key
            if HH.ReminderButton then HH.ReminderButton:PreviewSound() end
            RefreshSoundRowSelection()
        end)

        table.insert(soundRows, row)
        y = y - ROW_H
    end
    -- Small trailing gap after the list.
    y = y - 4

    RefreshSoundRowSelection()

    -- Sync checkbox visuals to live saved-variable state each time the panel
    -- is shown. The checkboxes are purely visual — HookClick handles writes,
    -- this handles reads.
    panel:SetScript("OnShow", function(self)
        cbEnabled:SetChecked(HH.db.settings.enabled)
        cbMinimap:SetChecked(HH.db.settings.showMinimap ~= false)
        cbDungeons:SetChecked(HH.db.settings.dungeonPullAlerts == true)
        cbLocked:SetChecked(HH.chardb.settings.button.locked)
        cbSoundEnabled:SetChecked(HH.chardb.settings.soundEnabled)
        cbTest:SetChecked(HH.ReminderButton and HH.ReminderButton:IsTestMode() or false)
        RefreshSoundRowSelection()
    end)
end

-- ============================================================================
-- Bosses tab
-- ============================================================================

function Config:BuildBossesTab(panel)
    -- Top row: raid selector dropdown
    local raidItems = {}
    for _, r in ipairs(HH.Database.RAIDS) do
        table.insert(raidItems, { label = r.name, value = r.key })
    end

    local selectedRaid = HH.Database.RAIDS[1].key
    local raidLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    raidLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
    raidLabel:SetText("Raid:")
    raidLabel:SetTextColor(D.label[1], D.label[2], D.label[3])

    -- Width trimmed from 200 to 140 so the top row can also fit the
    -- Reset / Export / Import buttons on the right without overlap.
    -- "Serpentshrine Cavern" still fits comfortably at this width.
    local raidDD = MakeDropdown(panel, 140, raidItems, function(value)
        selectedRaid = value
        Config:RefreshBossList()
    end, HH.Database.RAIDS[1].name, "raid")
    raidDD:SetPoint("LEFT", raidLabel, "RIGHT", 4, -2)

    -- Reset / Import / Export buttons (top-right of the bosses tab).
    --
    -- We wrap the click handlers in pcall so any error surfaces in chat
    -- instead of vanishing silently — a plain :SetScript("OnClick", ...)
    -- callback that raises will just produce a yellow error frame the
    -- player may have disabled. The pcall guarantees the addon at least
    -- tells you *something* happened.
    local function SafeClick(label, fn)
        local ok, err = pcall(fn)
        if not ok then
            HH:Print(label .. " failed: " .. tostring(err), HH.Colors.error)
        end
    end

    -- StaticPopup confirmation for Reset. Registered once; subsequent
    -- invocations of BuildBossesTab overwrite the same slot harmlessly.
    StaticPopupDialogs["HEROHELPER_RESET_BOSSES"] = {
        text         = "Reset all per-boss HeroHelper settings to defaults?\n\nThis clears every override — HP thresholds, phase picks, disabled flags — for every boss in every raid. The action cannot be undone.",
        button1      = YES or "Yes",
        button2      = NO  or "No",
        OnAccept     = function()
            HH.chardb.bosses = {}
            Config:RefreshBossList()
            HH:Print("All per-boss settings reset to database defaults.", HH.Colors.success)
        end,
        timeout      = 0,
        whileDead    = true,
        hideOnEscape = true,
        preferredIndex = 3, -- avoid taint issues with UIParent reparent
    }

    local resetBtn = MakeFlatButton(panel, "Reset", 55, 22)
    resetBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -156, 0)
    resetBtn:RegisterForClicks("LeftButtonUp")
    resetBtn:SetScript("OnClick", function()
        SafeClick("Reset", function() StaticPopup_Show("HEROHELPER_RESET_BOSSES") end)
    end)

    local exportBtn = MakeFlatButton(panel, "Export", 70, 22)
    exportBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -80, 0)
    exportBtn:RegisterForClicks("LeftButtonUp")
    exportBtn:SetScript("OnClick", function()
        SafeClick("Export", function() Config:ShowExportPopup() end)
    end)

    local importBtn = MakeFlatButton(panel, "Import", 70, 22)
    importBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -4, 0)
    importBtn:RegisterForClicks("LeftButtonUp")
    importBtn:SetScript("OnClick", function()
        SafeClick("Import", function() Config:ShowImportPopup() end)
    end)

    -- Scrollable list for boss rows
    local scrollFrame = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT",     panel, "TOPLEFT",     0, -34)
    scrollFrame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -24, 0)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(FRAME_WIDTH - 2*PADDING - 30, 1)
    scrollFrame:SetScrollChild(content)

    panel._scrollFrame = scrollFrame
    panel._scrollContent = content
    panel._rows = {}
    panel._getSelectedRaid = function() return selectedRaid end

    Config:RefreshBossList()
end

function Config:RefreshBossList()
    local panel = configState.frame and configState.frame.bossPanel
    if not panel then return end
    local content = panel._scrollContent
    local raidKey = panel._getSelectedRaid()

    -- Release old rows
    for _, row in ipairs(panel._rows) do row:Hide() end
    panel._rows = {}

    local y = 0
    local rowHeight = 30

    for bossID, boss in HH.Database:IterRaid(raidKey) do
        local row = CreateFrame("Frame", nil, content)
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
        row:SetSize(content:GetWidth(), rowHeight)

        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.08, 0.08, 0.10, 0.6)

        -- Boss name
        local name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        name:SetPoint("LEFT", row, "LEFT", 4, 0)
        name:SetWidth(150)
        name:SetJustifyH("LEFT")
        name:SetText(boss.name)
        name:SetTextColor(D.value[1], D.value[2], D.value[3])

        -- Current trigger config (merged default + override)
        local cfg = HH.Database:GetTriggerConfig(bossID) or boss.default

        -- "Phase" is only a valid trigger type for bosses that have a
        -- yell-pattern table in the database — the Triggers module advances
        -- phase counters by matching boss-yell text against
        -- Database.yells[phase]. Bosses without a yells table can't be
        -- phase-detected, so we omit the "Phase" option from their
        -- dropdowns entirely instead of letting the player pick a trigger
        -- that would silently never fire.
        local canPhase = boss.yells ~= nil and next(boss.yells) ~= nil

        local typeItems = {
            { label = "Pull",  value = "pull" },
            { label = "HP %",  value = "hp" },
        }
        if canPhase then
            table.insert(typeItems, { label = "Phase", value = "phase" })
        end
        table.insert(typeItems, { label = "Off", value = "off" })

        -- HP / Phase edit box (shared slot, switched based on type)
        local edit = CreateFrame("EditBox", nil, row)
        edit:SetSize(50, 20)
        edit:SetPoint("RIGHT", row, "RIGHT", -8, 0)
        edit:SetAutoFocus(false)
        edit:SetFontObject("GameFontHighlightSmall")
        edit:SetJustifyH("CENTER")
        edit:SetMaxLetters(3)
        local editBg = edit:CreateTexture(nil, "BACKGROUND")
        editBg:SetAllPoints()
        editBg:SetColorTexture(0.10, 0.10, 0.13, 1)
        AddThinBorder(edit, D.border[1], D.border[2], D.border[3], D.borA)

        local function UpdateEdit()
            -- Read-only: pull the effective config (default + any existing
            -- override) without materializing a blank override row.
            local effective = HH.Database:GetTriggerConfig(bossID) or boss.default or {}
            if effective.type == "hp" then
                edit:Show()
                edit:SetText(tostring(effective.hp or 35))
            elseif effective.type == "phase" then
                edit:Show()
                edit:SetText(tostring(effective.phase or 2))
            else
                edit:Hide()
            end
        end

        edit:SetScript("OnEnterPressed", function(self)
            local v = tonumber(self:GetText())
            HH.chardb.bosses[bossID] = HH.chardb.bosses[bossID] or {}
            local override = HH.chardb.bosses[bossID]
            local effective = HH.Database:GetTriggerConfig(bossID) or boss.default or {}
            if effective.type == "hp" and v then
                override.hp = math.max(1, math.min(99, v))
            elseif effective.type == "phase" and v then
                override.phase = math.max(1, math.min(10, v))
            end
            self:ClearFocus()
            UpdateEdit()
        end)
        edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

        local initialLabel = "Pull"
        if cfg.type == "hp" then
            initialLabel = "HP %"
        elseif cfg.type == "phase" and canPhase then
            initialLabel = "Phase"
        elseif cfg.type == "off" then
            initialLabel = "Off"
        end
        -- If a stale saved override says "phase" on a boss that has no
        -- yells, the Phase option won't be in the dropdown for this boss.
        -- Leave initialLabel at "Pull" so the dropdown shows a selectable
        -- state rather than a ghost "Phase" entry the player can't re-pick.

        local typeDD = MakeDropdown(row, 80, typeItems, function(value)
            HH.chardb.bosses[bossID] = HH.chardb.bosses[bossID] or {}
            local override = HH.chardb.bosses[bossID]
            if value == "off" then
                override.enabled = false
                override.type = nil
            else
                override.enabled = true
                override.type = value
                if value == "hp"    and not override.hp    then override.hp    = boss.default.hp    or 35 end
                if value == "phase" and not override.phase then override.phase = boss.default.phase or 2 end
            end
            UpdateEdit()
        end, initialLabel)
        typeDD:SetPoint("LEFT", name, "RIGHT", 0, -2)

        UpdateEdit()

        table.insert(panel._rows, row)
        y = y - rowHeight - 2
    end

    content:SetHeight(math.max(-y, 1))
end

-- ============================================================================
-- Show / hide / toggle
-- ============================================================================

function Config:Show()
    if not configState.frame then self:CreateFrame() end
    configState.frame:Show()
    configState.visible = true
end

function Config:Hide()
    if configState.frame then
        configState.frame:Hide()
    end
    configState.visible = false
end

function Config:Toggle()
    if configState.visible then self:Hide() else self:Show() end
end

-- ============================================================================
-- Import / Export popup
-- ============================================================================
--
-- A single shared popup frame used for both export and import. In export
-- mode, the edit box is read-only and pre-filled with the serialized config
-- string; the user clicks CTRL+A / CTRL+C to copy. In import mode, the edit
-- box is writable and the [Import] button parses the contents.

local popup

local function CreatePopup()
    if popup then return popup end

    local f = CreateFrame("Frame", "HeroHelperIOPopup", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    -- Sized to comfortably fit the full DB hash (~900 base64 chars, which
    -- wraps to ~7 lines at this width) plus headroom for the title,
    -- help line and action row.
    f:SetSize(520, 360)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:Hide()

    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 8,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        f:SetBackdropColor(D.bg[1], D.bg[2], D.bg[3], D.bgA)
        f:SetBackdropBorderColor(D.border[1], D.border[2], D.border[3], D.borA)
    end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", PADDING, -PADDING)
    f.title = title

    local help = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    help:SetPoint("TOPLEFT", f, "TOPLEFT", PADDING, -PADDING - 16)
    help:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PADDING, -PADDING - 16)
    help:SetJustifyH("LEFT")
    help:SetTextColor(D.label[1], D.label[2], D.label[3])
    f.help = help

    -- Multi-line-ish edit box (TBC Classic has a working ScrollingEditBox,
    -- but for our short single-line share strings a plain EditBox is enough;
    -- we just widen it and disable autofocus).
    --
    -- The background lives on a real Frame rather than a bare Texture so
    -- AddThinBorder can hang its four edge textures on it — textures have
    -- no CreateTexture method, which was the original silent crash.
    local editBox = CreateFrame("Frame", nil, f)
    editBox:SetPoint("TOPLEFT",     f, "TOPLEFT",     PADDING, -PADDING - 44)
    editBox:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PADDING,  PADDING + 28)
    local editBg = editBox:CreateTexture(nil, "BACKGROUND")
    editBg:SetAllPoints(editBox)
    editBg:SetColorTexture(0.07, 0.07, 0.09, 1)
    AddThinBorder(editBox, D.border[1], D.border[2], D.border[3], D.borA)

    local edit = CreateFrame("EditBox", nil, editBox)
    edit:SetPoint("TOPLEFT",     editBox, "TOPLEFT",     4,  -4)
    edit:SetPoint("BOTTOMRIGHT", editBox, "BOTTOMRIGHT", -4,  4)
    edit:SetFontObject("GameFontHighlightSmall")
    edit:SetAutoFocus(false)
    edit:SetMultiLine(true)
    edit:SetMaxLetters(4096)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus(); f:Hide() end)
    f.edit = edit

    -- Action button (changes label + behavior depending on mode)
    local actionBtn = MakeFlatButton(f, "OK", 110, 22)
    actionBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PADDING - 120, PADDING)
    f.actionBtn = actionBtn

    local closeBtn = MakeFlatButton(f, "Close", 110, 22)
    closeBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PADDING, PADDING)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- ESC closes
    table.insert(UISpecialFrames, "HeroHelperIOPopup")

    popup = f
    return f
end

function Config:ShowExportPopup()
    local f = CreatePopup()
    f.title:SetText("|cFFFF7D1AHeroHelper|r  |cFF66666BExport Hash|r")
    f.help:SetText("Copy this hash (Ctrl+A, Ctrl+C) and share it with your raid.")

    local str = HH.Database:ExportHash()
    f.edit:SetText(str)
    f.edit:HighlightText()
    f.edit:SetFocus()

    f.actionBtn.label:SetText("Select All")
    f.actionBtn:SetScript("OnClick", function()
        f.edit:SetFocus()
        f.edit:HighlightText()
    end)

    f:Show()
    f:Raise()
end

function Config:ShowImportPopup()
    local f = CreatePopup()
    f.title:SetText("|cFFFF7D1AHeroHelper|r  |cFF66666BImport Hash|r")
    f.help:SetText("Paste an import hash below, then click Apply. Existing per-boss settings will be overwritten.")
    f.edit:SetText("")
    f.edit:SetFocus()

    f.actionBtn.label:SetText("Apply")
    f.actionBtn:SetScript("OnClick", function()
        local str = f.edit:GetText()
        local ok, applied, skipped, err = HH.Database:ImportHash(str)
        if not ok then
            HH:Print("Import failed: " .. tostring(err), HH.Colors.error)
            return
        end
        HH:Print(string.format("Imported %d boss entries (%d skipped).", applied, skipped), HH.Colors.success)
        Config:RefreshBossList()
        f:Hide()
    end)

    f:Show()
    f:Raise()
end
