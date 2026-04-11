--[[
    HeroHelper - Minimap Module

    Self-contained minimap button following the same pattern used by the
    FishingKit addon (no LibDBIcon dependency). Left-click opens the config
    panel, right-click toggles the reminder button lock, drag repositions the
    button around the minimap edge.
]]

local ADDON_NAME, HH = ...

HH.Minimap = {}
local M = HH.Minimap

local minimapButton
local minimapAngle = 225

function M:Initialize()
    if HH.db and HH.db.settings and HH.db.settings.minimapAngle then
        minimapAngle = HH.db.settings.minimapAngle
    end
    self:CreateButton()
end

function M:CreateButton()
    if minimapButton then return end

    local btn = CreateFrame("Button", "HeroHelperMinimapButton", Minimap)
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:SetMovable(true)
    btn:EnableMouse(true)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")

    -- Dark circle background (matches LibDBIcon style)
    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetPoint("TOPLEFT", 7, -5)

    -- Icon (Bloodlust spell icon — shared between factions as art)
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(17, 17)
    icon:SetPoint("TOPLEFT", 7, -6)
    icon:SetTexture("Interface\\Icons\\Spell_Nature_Bloodlust")
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    btn.icon = icon

    -- Border (standard minimap button border ring)
    local overlay = btn:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetPoint("TOPLEFT", 0, 0)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local function UpdatePosition()
        local angle = math.rad(minimapAngle)
        local x = math.cos(angle) * 80
        local y = math.sin(angle) * 80
        btn:ClearAllPoints()
        btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
    end

    btn:SetScript("OnClick", function(self, mouseButton)
        if mouseButton == "LeftButton" then
            if HH.Config and HH.Config.Toggle then
                HH.Config:Toggle()
            end
        elseif mouseButton == "RightButton" then
            HH.chardb.settings.button.locked = not HH.chardb.settings.button.locked
            if HH.ReminderButton and HH.ReminderButton.ApplyLock then
                HH.ReminderButton:ApplyLock()
            end
            HH:Print("Reminder button " .. (HH.chardb.settings.button.locked and "locked" or "unlocked") .. ".", HH.Colors.success)
        end
    end)

    btn:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function(self)
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            cx, cy = cx / scale, cy / scale
            minimapAngle = math.deg(math.atan2(cy - my, cx - mx))
            UpdatePosition()
        end)
    end)
    btn:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        if HH.db and HH.db.settings then
            HH.db.settings.minimapAngle = minimapAngle
        end
    end)

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("|cFFFF7D1AHeroHelper|r")
        GameTooltip:AddLine("Left-click: Options", 1, 1, 1)
        GameTooltip:AddLine("Right-click: Toggle reminder lock", 1, 1, 1)
        GameTooltip:AddLine("Drag: Move button", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    UpdatePosition()

    if HH.db and HH.db.settings and HH.db.settings.showMinimap == false then
        btn:Hide()
    else
        btn:Show()
    end

    minimapButton = btn
end

function M:Show()
    if not minimapButton then self:CreateButton() end
    if minimapButton then minimapButton:Show() end
    if HH.db and HH.db.settings then HH.db.settings.showMinimap = true end
end

function M:Hide()
    if minimapButton then minimapButton:Hide() end
    if HH.db and HH.db.settings then HH.db.settings.showMinimap = false end
end

function M:Toggle()
    if minimapButton and minimapButton:IsShown() then
        self:Hide()
    else
        self:Show()
    end
end
