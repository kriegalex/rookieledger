-- Tooltip.lua: what a kind of monster gave you so far, under its tooltip.
--
--   RookieLedger                   looted 12x
--     Linen Cloth                    58% x1.4
--     Darkhound Blood (quest)           3/7
--     Coin                          15 copper
--
-- The figures are this account's own record, the only one the addon has: it receives nothing from the site.
-- Under MIN_CORPSES corpses a rate is told as "3 of 7", not as a percentage that so few corpses cannot carry.
-- ns.here.tooltip (per character) holds the two settings: off, and from, the lowest item quality shown.
local _, ns = ...

local Tooltip = {}
ns.Tooltip = Tooltip

local L = ns.L
local MAX_LINES = 8
local MIN_CORPSES = 10
local QUALITIES = 4   -- the filter offers "all" (0) up to this quality (epic)
local GREY, GOLD = "|cff8a8a8a", "|cffe6b422"

local ItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

-- k of n as a percentage, or as "k/n" while n is too small for one.
local function Rate(k, n)
    if n >= MIN_CORPSES then
        return L.percent:format(math.floor(100 * k / n + 0.5))
    end
    return k .. "/" .. n
end

-- The item's name in the colour of its quality, and that quality; "item 2589" and nil while the client has neither.
local function ItemLabel(item)
    local name, _, quality = ns.Try(ItemInfo, item)
    name, quality = ns.Plain(name), ns.Plain(quality)
    if type(name) ~= "string" or name == "" then
        return GREY .. L.item:format(item) .. "|r", nil
    end
    local colour = type(quality) == "number" and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    return (colour and colour.hex or "|cffffffff") .. name .. "|r", type(quality) == "number" and quality or nil
end

local function CoinText(copper)
    return ns.Plain(ns.Try(GetCoinTextureString, copper)) or L.copper:format(copper)
end

-- The name the game gives a quality ("Uncommon"), in its colour; "All" for 0.
function Tooltip.QualityName(quality)
    if quality == 0 then
        return L.tipAll
    end
    local name = _G["ITEM_QUALITY" .. quality .. "_DESC"] or L["quality" .. quality]
    local colour = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    return (colour and colour.hex or "") .. name .. (colour and "|r" or "")
end

-- What the tooltip of that kind of creature says: { { left, right }, ... }, the heading first. Nil when the record
-- holds nothing of it, or the tooltip is switched off.
function Tooltip.Lines(creature)
    local settings = ns.here.tooltip
    if settings.off then
        return nil
    end
    local own = ns.db.own
    local entry = ns.Record.Looted(own, creature)
    local quest, prefix = {}, creature .. ":"
    for key, q in pairs(own.q) do
        if type(key) == "string" and key:sub(1, #prefix) == prefix and type(q) == "table" then
            quest[#quest + 1] = { tonumber(key:sub(#prefix + 1)) or 0, q }
        end
    end
    if not entry and #quest == 0 then
        return nil
    end
    local n = entry and entry.n or 0
    local lines = { { GOLD .. "RookieLedger|r", GREY .. L.tipLooted:format(n) .. "|r" } }

    -- The items, the most frequent first; those under the quality asked for are left out.
    local from = type(settings.from) == "number" and settings.from or 0
    local rows = {}
    for item, pair in pairs(entry and entry.i or {}) do
        local label, quality = ItemLabel(item)
        if not quality or quality >= from then
            rows[#rows + 1] = { item = item, label = label, quantity = pair[1], times = pair[2] }
        end
    end
    table.sort(rows, function(a, b)
        if a.times ~= b.times then
            return a.times > b.times
        end
        return a.item < b.item
    end)
    for i = 1, math.min(#rows, MAX_LINES) do
        local row = rows[i]
        local right = Rate(row.times, n)
        local each = row.quantity / row.times
        if each >= 1.05 then
            right = right .. GREY .. (" x%.1f"):format(each) .. "|r"
        end
        lines[#lines + 1] = { "  " .. row.label, right }
    end
    if #rows > MAX_LINES then
        lines[#lines + 1] = { GREY .. "  " .. L.tipMore:format(#rows - MAX_LINES) .. "|r", "" }
    end

    -- Quest items have their own count: the corpses looted while the quest wanted them.
    table.sort(quest, function(a, b) return a[1] < b[1] end)
    for _, q in ipairs(quest) do
        local chances, drops = tonumber(q[2].n) or 0, tonumber(q[2].k) or 0
        lines[#lines + 1] = { "  " .. ItemLabel(q[1]) .. GREY .. " (" .. L.tipQuest .. ")|r",
            chances > 0 and Rate(drops, chances) or GREY .. "?|r" }
    end

    if entry and entry.cn > 0 and entry.c > 0 then   -- a kind of monster that never held coin gets no such line
        lines[#lines + 1] = { "  " .. L.tipCoin, CoinText(math.floor(entry.c / entry.cn + 0.5)) }
    end
    return lines
end

-- The hook ----------------------------------------------------------------------

local failed   -- an error in a tooltip would come back at every mouse move: it is said once, by a repository copy

local function OnUnit(tip)
    if tip ~= GameTooltip or tip.rookieLedgerDone then
        return
    end
    tip.rookieLedgerDone = true
    local ok, problem = pcall(function()
        local _, unit = tip:GetUnit()
        unit = ns.Plain(unit) or "mouseover"
        if ns.Plain(ns.Try(UnitIsPlayer, unit)) ~= false then
            return
        end
        local guid = ns.Plain(ns.Try(UnitGUID, unit))
        local kind, id = "", nil
        if type(guid) == "string" then
            kind, id = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
        end
        if kind ~= "Creature" and kind ~= "Vehicle" then
            return
        end
        local lines = Tooltip.Lines(tonumber(id))
        if not lines then
            return
        end
        tip:AddLine(" ")
        for _, line in ipairs(lines) do
            tip:AddDoubleLine(line[1], line[2], 1, 1, 1, 1, 0.82, 0)
        end
        tip:Show()
    end)
    if not ok and not failed then
        failed = true
        if ns.version == "dev" then
            ns.Print(tostring(problem))
        end
    end
end

function Tooltip.Init()
    if type(GameTooltip) ~= "table" then
        return
    end
    GameTooltip:HookScript("OnTooltipCleared", function(tip)
        tip.rookieLedgerDone = nil
    end)
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, OnUnit)
    elseif GameTooltip:HasScript("OnTooltipSetUnit") then
        GameTooltip:HookScript("OnTooltipSetUnit", OnUnit)
    end
end

-- Settings ------------------------------------------------------------------------

function Tooltip.Toggle()
    local settings = ns.here.tooltip
    settings.off = not settings.off or nil
    ns.Print(settings.off and L.tooltipOff or L.tooltipOn)
    return not settings.off
end

-- Shows items from that quality up: 0 for all of them.
function Tooltip.SetFrom(quality)
    ns.here.tooltip.from = math.max(0, math.min(QUALITIES, quality))
end

function Tooltip.From()
    local from = ns.here.tooltip.from
    return type(from) == "number" and from or 0
end

Tooltip.QUALITIES = QUALITIES
