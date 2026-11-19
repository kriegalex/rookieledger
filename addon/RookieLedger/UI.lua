-- UI.lua: the window (what was recorded last, the counts of this session and in total), the minimap button and the
-- page in the game's AddOns options.
--
-- Nothing here records or changes the record: it shows ns.Totals(), ns.session and the log Core.lua keeps. Whatever
-- the client lacks (a frame type, the minimap libraries) costs that part of the interface and nothing else: every
-- entry point runs guarded, so recording goes on.
local ADDON, ns = ...

local UI = {}
ns.UI = UI

local L = ns.L
local ICON = "Interface\\AddOns\\" .. ADDON .. "\\Media\\Icon"
local WINDOW = "RookieLedgerWindow"
local ROWS = { { "c", "rowC" }, { "s", "rowS" }, { "d", "rowD" }, { "g", "rowG" }, { "m", "rowM" } }

local window, cells, messages   -- the window, its { [kind] = { session, total } } figures and its log
local dbicon, minimapCheck
local tooltipCheck, showFrom   -- the options page's tooltip switch, and what sets its quality control to the setting

-- Runs f. An error stops f alone; a copy of the repository says what it was.
local function Guard(f, ...)
    local ok, problem = pcall(f, ...)
    if not ok and ns.version == "dev" then
        ns.Print(tostring(problem))
    end
    return ok
end

local function Text(parent, font, justify)
    local text = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    text:SetJustifyH(justify or "LEFT")
    return text
end

-- The window --------------------------------------------------------------------

local function Build()
    local f = CreateFrame("Frame", WINDOW, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    f:Hide()
    f:SetSize(460, 420)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
    end
    local at = ns.here.window
    if type(at.point) == "string" and type(at.x) == "number" and type(at.y) == "number" then
        f:SetPoint(at.point, UIParent, at.point, at.x, at.y)
    else
        f:SetPoint("CENTER")
    end
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint(1)
        at.point, at.x, at.y = point, x, y
    end)
    if type(UISpecialFrames) == "table" then
        table.insert(UISpecialFrames, WINDOW)   -- Escape closes it
    end

    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetSize(24, 24)
    icon:SetPoint("TOPLEFT", 12, -10)
    icon:SetTexture(ICON)
    local title = Text(f, "GameFontNormalLarge")
    title:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    title:SetText("RookieLedger")
    local version = Text(f, "GameFontDisableSmall", "RIGHT")
    version:SetPoint("TOPRIGHT", -34, -16)
    version:SetText(ns.version)
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)

    -- The counts: one line per section of the record, this session and in total.
    local top = -46
    for column, key in ipairs({ "session", "total" }) do
        local head = Text(f, "GameFontNormalSmall", "RIGHT")
        head:SetPoint("TOPRIGHT", f, "TOPLEFT", 330 + (column - 1) * 110, top)
        head:SetText(L[key])
    end
    cells = {}
    for i, row in ipairs(ROWS) do
        local y = top - 4 - i * 16
        local label = Text(f)
        label:SetPoint("TOPLEFT", 16, y)
        label:SetText(L[row[2]])
        cells[row[1]] = {}
        for column = 1, 2 do
            local cell = Text(f, "GameFontHighlightSmall", "RIGHT")
            cell:SetPoint("TOPRIGHT", f, "TOPLEFT", 330 + (column - 1) * 110, y)
            cells[row[1]][column] = cell
        end
    end

    local recent = Text(f, "GameFontNormalSmall")
    recent:SetPoint("TOPLEFT", 16, top - 4 - (#ROWS + 1) * 16 - 6)
    recent:SetText(L.recent)

    -- The log: a chat-like frame, so that the items it names can be pointed at and clicked like links in the chat.
    local m = CreateFrame("ScrollingMessageFrame", nil, f)
    m:SetPoint("TOPLEFT", recent, "BOTTOMLEFT", 0, -6)
    m:SetPoint("BOTTOMRIGHT", -16, 14)
    m:SetFontObject(GameFontHighlightSmall)
    m:SetJustifyH("LEFT")
    m:SetFading(false)
    m:SetMaxLines(100)
    if m.SetInsertMode then
        -- The newest line at the top, under the heading, instead of at the bottom of an empty frame as in the chat.
        pcall(m.SetInsertMode, m, SCROLLING_MESSAGE_FRAME_INSERT_MODE_TOP or "TOP")
    end
    m:EnableMouseWheel(true)
    m:SetScript("OnMouseWheel", function(self, delta)
        if delta > 0 then
            self:ScrollUp()
        else
            self:ScrollDown()
        end
    end)
    if m.SetHyperlinksEnabled then
        m:SetHyperlinksEnabled(true)
        m:SetScript("OnHyperlinkEnter", function(self, link)
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            GameTooltip:SetHyperlink(link)
            GameTooltip:Show()
        end)
        m:SetScript("OnHyperlinkLeave", function()
            GameTooltip:Hide()
        end)
        m:SetScript("OnHyperlinkClick", function(self, link, text, button)
            if SetItemRef then
                SetItemRef(link, text, button, self)
            end
        end)
    end
    messages = m

    f:SetScript("OnShow", UI.Refresh)
    window = f
end

local function Fill()
    local totals, session = ns.Totals(), ns.session
    for _, row in ipairs(ROWS) do
        local kind = row[1]
        cells[kind][1]:SetText(tostring(session[kind] or 0))
        cells[kind][2]:SetText(tostring(totals[kind] or 0))
    end
    messages:Clear()
    local any = false
    for _, entry in ipairs(ns.here.log) do
        if type(entry) == "table" and type(entry[1]) == "number" and type(entry[3]) == "string" then
            messages:AddMessage("|cff8a8a8a" .. date("%H:%M", entry[1]) .. "|r  " .. entry[3])
            any = true
        end
    end
    if not any then
        messages:AddMessage("|cff8a8a8a" .. L.logEmpty .. "|r")
    end
end

-- Shows the window's figures and log as they are now, and the options page's switches as the settings are.
-- Nothing to do for the window while it is closed: opening it comes here.
function UI.Refresh()
    if window and window:IsShown() then
        Guard(Fill)
    end
    if tooltipCheck then
        tooltipCheck:SetChecked(not ns.here.tooltip.off)
    end
    if showFrom then
        Guard(showFrom)
    end
end

function UI.Toggle()
    if not window and not Guard(Build) then
        return
    end
    if window:IsShown() then
        window:Hide()
    else
        window:Show()
    end
end

-- The minimap button ----------------------------------------------------------------

local function Library(name)
    if LibStub == nil then
        return nil
    end
    local ok, library = pcall(LibStub, name, true)
    return ok and library or nil
end

local function Tooltip(tip)
    local totals, session = ns.Totals(), ns.session
    tip:AddDoubleLine("RookieLedger", ns.version, 0.9, 0.7, 0.13, 0.6, 0.6, 0.6)
    tip:AddDoubleLine(" ", L.session .. " / " .. L.total, 1, 1, 1, 0.6, 0.6, 0.6)
    for _, row in ipairs(ROWS) do
        tip:AddDoubleLine(L[row[2]], (session[row[1]] or 0) .. " / " .. (totals[row[1]] or 0), 1, 1, 1, 1, 1, 1)
    end
    tip:AddLine(" ")
    tip:AddLine(L.hintLeft, 0.6, 0.6, 0.6)
    tip:AddLine(L.hintRight, 0.6, 0.6, 0.6)
end

-- Through LibDataBroker and LibDBIcon, as most addons do: addons that gather the minimap's buttons find it, and
-- data broker bars can show it. A copy of the repository has no libraries and no button.
local function MinimapButton()
    local broker, icons = Library("LibDataBroker-1.1"), Library("LibDBIcon-1.0")
    if not broker or not icons then
        return
    end
    local object = broker:NewDataObject(ADDON, {
        type = "launcher",
        label = "RookieLedger",
        icon = ICON,
        OnClick = function(_, button)
            if button == "RightButton" then
                Guard(ns.Command, "token")
            else
                UI.Toggle()
            end
        end,
        OnTooltipShow = function(tip)
            Guard(Tooltip, tip)
        end,
    })
    icons:Register(ADDON, object, ns.here.minimap)
    dbicon = icons
end

function UI.ToggleMinimap()
    if not dbicon then
        ns.Print(L.minimapNone)
        return
    end
    local at = ns.here.minimap
    at.hide = not at.hide or nil
    Guard(function()
        if at.hide then
            dbicon:Hide(ADDON)
        else
            dbicon:Show(ADDON)
        end
    end)
    if minimapCheck then
        minimapCheck:SetChecked(not at.hide)
    end
    ns.Print(at.hide and L.minimapOff or L.minimapOn)
end

-- The page in the game's AddOns options ------------------------------------------------

-- The tooltip's two settings, under `above`: a switch, and the quality from which items are shown. The game's own
-- drop-down where the client has it, else a button that goes from one quality to the next.
local function TooltipOptions(panel, above)
    local Tip = ns.Tooltip
    local check = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    check:SetPoint("TOPLEFT", above, "BOTTOMLEFT", above == minimapCheck and 0 or -2, -10)
    check:SetChecked(not ns.here.tooltip.off)
    check:SetScript("OnClick", function()
        Tip.Toggle()
        UI.Refresh()
    end)
    local label = Text(panel, "GameFontHighlight")
    label:SetPoint("LEFT", check, "RIGHT", 4, 0)
    label:SetText(L.optTooltip)
    tooltipCheck = check

    local from = Text(panel, "GameFontHighlight")
    from:SetPoint("TOPLEFT", check, "BOTTOMLEFT", 6, -14)
    from:SetText(L.optFrom)

    local ok, dropdown = pcall(CreateFrame, "DropdownButton", nil, panel, "WowStyle1DropdownTemplate")
    if ok and dropdown and dropdown.SetupMenu then
        dropdown:SetPoint("LEFT", from, "RIGHT", 10, 0)
        dropdown:SetSize(180, 26)
        dropdown:SetupMenu(function(_, root)
            for quality = 0, Tip.QUALITIES do
                root:CreateRadio(Tip.QualityName(quality), function(q) return Tip.From() == q end, Tip.SetFrom, quality)
            end
        end)
        showFrom = function()
            if dropdown.GenerateMenu then
                dropdown:GenerateMenu()
            end
        end
        return
    end
    local button = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    button:SetPoint("LEFT", from, "RIGHT", 10, 0)
    button:SetSize(180, 24)
    showFrom = function()
        button:SetText(Tip.QualityName(Tip.From()))
    end
    button:SetScript("OnClick", function()
        Tip.SetFrom((Tip.From() + 1) % (Tip.QUALITIES + 1))
        showFrom()
    end)
    showFrom()
end

local function Options()
    local panel = CreateFrame("Frame")
    panel.name = "RookieLedger"
    local title = Text(panel, "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("RookieLedger " .. ns.version)
    local about = Text(panel, "GameFontHighlight")
    about:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
    about:SetPoint("RIGHT", panel, "RIGHT", -16, 0)   -- as wide as the page, whatever its size
    about:SetSpacing(3)
    about:SetText(L.optAbout)

    local open = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    open:SetPoint("TOPLEFT", about, "BOTTOMLEFT", 0, -16)
    open:SetSize(200, 24)
    open:SetText(L.optOpen)
    open:SetScript("OnClick", UI.Toggle)

    if dbicon then
        local check = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        check:SetPoint("TOPLEFT", open, "BOTTOMLEFT", -2, -10)
        check:SetChecked(not ns.here.minimap.hide)
        check:SetScript("OnClick", UI.ToggleMinimap)
        local label = Text(panel, "GameFontHighlight")
        label:SetPoint("LEFT", check, "RIGHT", 4, 0)
        label:SetText(L.optMinimap)
        minimapCheck = check
    end

    Guard(TooltipOptions, panel, minimapCheck or open)

    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        Settings.RegisterAddOnCategory(Settings.RegisterCanvasLayoutCategory(panel, panel.name))
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

function UI.Init()
    Guard(MinimapButton)
    Guard(Options)
end
