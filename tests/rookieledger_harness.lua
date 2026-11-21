-- Runs the RookieLedger addon outside the game: a stub of the WoW API with a simulated clock. The stub has no way
-- to send anything: an attempt is an error, and a failed check at the end when the addon caught that error.
--   lua5.1 tests/rookieledger_harness.lua addon/RookieLedger [saved-variables-out.lua]
-- Prints "ok <name>" per check and exits non-zero on the first failure. With a second argument it writes client A's
-- RookieLedgerDB and RookieLedgerGroup in the layout the game gives a saved-variables file, for the server's parser
-- tests.
local ADDON_DIR, OUT = arg[1], arg[2]
local FILES = { "Core.lua", "Record.lua", "Scan.lua", "Group.lua", "Tooltip.lua", "UI.lua" }

local clock = 0
local timers = {}
local clients = {}

local function check(name, cond, detail)
    if not cond then
        io.stderr:write("FAILED " .. name .. (detail and (": " .. tostring(detail)) or "") .. "\n")
        os.exit(1)
    end
    print("ok " .. name)
end

local function run(seconds)
    local stop = clock + seconds
    while clock < stop do
        clock = clock + 0.1
        local due = {}
        for i = #timers, 1, -1 do
            if timers[i].at <= clock then
                due[#due + 1] = table.remove(timers, i)
            end
        end
        table.sort(due, function(a, b) return a.at < b.at end)
        for _, t in ipairs(due) do
            if t.client.online then
                t.f()
            end
        end
    end
end

-- A recipe's colour at a skill: thresholds = { yellow, green, grey }.
local function colourAt(thresholds, skill)
    if skill < thresholds[1] then return 0 elseif skill < thresholds[2] then return 1 elseif skill < thresholds[3] then return 2 end
    return 3
end

local function newClient(name)
    local c = { name = name, online = true, frames = {}, printed = {}, version = "@project-version@",
        profs = {}, window = nil, recipes = {}, bags = {}, loot = {}, items = {}, texts = {}, named = {}, quests = {},
        itemInfo = {}, buttons = {} }
    local env = setmetatable({}, { __index = _G })
    c.env = env
    env.print = function(text) c.printed[#c.printed + 1] = text end
    env.time = function() return 1794800000 + math.floor(clock) end
    env.GetTime = function() return clock end
    env.GetLocale = function() return "frFR" end
    env.GetBuildInfo = function() return "1.60.1", "70374" end
    env.C_AddOns = { GetAddOnMetadata = function(addon, field)
        return addon == "RookieLedger" and field == "Version" and c.version or nil
    end }
    env._G = env
    env.UnitGUID = function(unit)
        if unit == "mouseover" then return c.mouseover end
        if unit:match("^party") or unit:match("^raid") then return c.party and c.party[unit] end
        return unit == "target" and c.target or ("Player-6941-" .. name)
    end
    env.UnitIsPlayer = function(unit) return unit ~= "mouseover" end
    env.UnitName = function(unit) return unit == "target" and c.targetName or name end
    env.date = os.date
    env.IsInGroup = function() return c.grouped == true end
    -- The group: three members under group loot from uncommon up. c.party = { party1 = guid }, c.canLoot = { [guid]
    -- = whether the corpse is ours to open }, c.money the character's coin, c.rolls = { [roll] = item }.
    env.IsInRaid = function() return false end
    env.GetNumGroupMembers = function() return c.grouped and 3 or 0 end
    env.C_PartyInfo = { GetLootMethod = function() return 3 end }
    env.GetLootThreshold = function() return 2 end
    env.IsInInstance = function() return false, "none" end
    env.GetMoney = function() return c.money or 0 end
    env.CanLootUnit = function(guid) return (c.canLoot and c.canLoot[guid]) == true, true end
    env.GetLootRollItemLink = function(roll)
        return c.rolls and c.rolls[roll] and ("|Hitem:" .. c.rolls[roll] .. "::|h[Bâton de Zorglub]|h") or nil
    end
    env.GetLootRollItemInfo = function() return 132089, "Bâton de Zorglub", 1, 2, false, true, true end
    env.LOOT_ITEM_SELF, env.LOOT_ITEM = "Vous recevez le butin : %s.", "%s reçoit le butin : %s."
    env.LOOT_ITEM_MULTIPLE, env.LOOT_MONEY_SPLIT = "%s reçoit le butin : %sx%d.", "Votre part du butin est de %s."
    env.GOLD_AMOUNT, env.SILVER_AMOUNT, env.COPPER_AMOUNT = "%d Or", "%d Argent", "%d Cuivre"
    env.SlashCmdList, env.StaticPopupDialogs = {}, {}
    env.StaticPopup_Show = function(which) c.popup = which end
    -- A frame, a font string or a texture: the few methods the checks look at, and any other method as one that
    -- does nothing, so that the interface code runs to its end here.
    local function widget()
        local w = { events = {}, scripts = {}, lines = {}, shown = true }
        function w:RegisterEvent(event) self.events[event] = true end
        function w:RegisterUnitEvent(event, unit)
            assert(unit == "player", "unit events are asked for the player only")
            self.events[event] = true
        end
        function w:SetScript(script, handler)
            self.scripts[script] = handler
            if script == "OnEvent" then self.handler = handler end
        end
        function w:Show()
            local was = self.shown
            self.shown = true
            if not was and self.scripts.OnShow then self.scripts.OnShow(self) end
        end
        function w:Hide() self.shown = false end
        function w:IsShown() return self.shown end
        function w:SetText(text) self.text = text end
        function w:SetChecked(value) self.checked = value end
        function w:AddMessage(text) self.lines[#self.lines + 1] = text end
        function w:Clear() self.lines = {} end
        function w:GetPoint() return "TOPLEFT", nil, "TOPLEFT", 40, -60 end
        function w:CreateFontString()
            local text = widget()
            c.texts[#c.texts + 1] = text
            return text
        end
        function w:CreateTexture() return widget() end
        function w:HookScript(script, handler) self.scripts[script] = handler end
        function w:HasScript() return true end
        function w:GetUnit() return nil, "mouseover" end
        function w:AddLine(text) self.lines[#self.lines + 1] = text end
        function w:AddDoubleLine(left, right) self.lines[#self.lines + 1] = left .. " = " .. right end
        function w:SetupMenu(generator) self.menu = generator end
        -- The game's methods start with a capital; anything else is a field somebody set, or nothing.
        return setmetatable(w, { __index = function(_, key)
            if type(key) == "string" and key:match("^%u") then return function() end end
        end })
    end
    env.CreateFrame = function(kind, frameName)
        if kind == "DropdownButton" and c.nodropdown then error("no such frame type") end
        local frame = widget()
        if kind == "DropdownButton" then c.dropdown = frame end
        if kind == "Button" then c.buttons[#c.buttons + 1] = frame end
        frame.kind = kind
        c.frames[#c.frames + 1] = frame
        if frameName then c.named[frameName] = frame end
        if kind == "ScrollingMessageFrame" then c.messages = frame end
        return frame
    end
    env.UIParent, env.GameTooltip, env.GameFontHighlightSmall, env.UISpecialFrames = widget(), widget(), {}, {}
    -- What the client knows of an item asked for by its id: c.itemInfo[id] = { name, quality }. Asked by its link,
    -- as the disenchants do, it answers as GetItemInfo further down.
    env.C_Item = { GetItemInfo = function(item)
        if type(item) == "number" then
            local info = c.itemInfo[item]
            if info then return info[1], nil, info[2] end
            return nil
        end
        return env.GetItemInfo(item)
    end }
    env.ITEM_QUALITY_COLORS = { [0] = { hex = "|cff9d9d9d" }, { hex = "|cffffffff" }, { hex = "|cff1eff00" } }
    env.ITEM_QUALITY2_DESC = "Inhabituel"
    env.Settings = {
        RegisterCanvasLayoutCategory = function(_, panelName) return panelName end,
        RegisterAddOnCategory = function(category) c.options = category end,
        OpenToCategory = function(category)
            if c.fighting then error("blocked in combat") end
            c.opened = category
        end,
    }
    -- The two libraries of the minimap button, as far as the addon uses them. c.nolibs: a copy without them.
    local libs = {
        ["LibDataBroker-1.1"] = { NewDataObject = function(_, _, object) c.broker = object return object end },
        ["LibDBIcon-1.0"] = {
            Register = function(_, _, object, db)
                assert(object.icon, "LibDBIcon refuses an object without an icon")
                c.icon = { db = db, shown = not db.hide }
            end,
            Hide = function() c.icon.shown = false end,
            Show = function() c.icon.shown = true end,
        },
    }
    env.LibStub = setmetatable({}, { __call = function(_, library) return not c.nolibs and libs[library] or nil end })
    env.C_Timer = { After = function(delay, f) timers[#timers + 1] = { at = clock + delay, f = f, client = c } end }
    local function sends()
        c.sent = true   -- the addon calls the game through pcall: the error alone could go unseen
        error("the addon tried to send an addon message")
    end
    env.C_ChatInfo = { RegisterAddonMessagePrefix = sends, SendAddonMessage = sends }
    env.SendAddonMessage, env.SendChatMessage = sends, sends
    env.GetProfessions = function() return 1, 2 end
    env.GetProfessionInfo = function(index)
        local p = c.profs[index]
        if p then
            return "prof", 1, p.rank, 300, 0, 0, p.line, p.bonus or 0
        end
    end
    env.C_TradeSkillUI = {
        IsTradeSkillReady = function() return c.window ~= nil end,
        IsDataSourceChanging = function() return false end,
        IsTradeSkillLinked = function() return false end,
        GetBaseProfessionInfo = function() return { professionID = c.window } end,
        GetAllRecipeIDs = function()
            local ids = {}
            for id, r in pairs(c.recipes) do
                if r.line == c.window then ids[#ids + 1] = id end
            end
            table.sort(ids)
            return ids
        end,
        GetRecipeInfo = function(id)
            local r = c.recipes[id]
            if not r then return nil end
            local rank
            for _, p in pairs(c.profs) do
                if p.line == r.line then rank = p.rank + (p.bonus or 0) end
            end
            return { learned = true, relativeDifficulty = colourAt(r.at, rank) }
        end,
    }
    env.C_Container = {
        GetContainerNumSlots = function(bag) return bag == 0 and 16 or 0 end,
        GetContainerItemInfo = function(bag, slot)
            local id = bag == 0 and c.bags[slot]
            if id then
                return { hyperlink = "|cff1eff00|Hitem:" .. id .. "::::::::|h[x]|h|r", stackCount = 1, quality = c.items[id].q }
            end
        end,
    }
    env.GetItemInfo = function(link)
        local item = c.items[tonumber(link:match("item:(%d+)"))]
        return "x", link, item.q, item.l, 0, "", "", 1, "", 0, 0, item.k
    end
    -- A loot slot is { item, quantity [, quest = true] [, from = { guid, quantity, ... }] } or { coin = "text", from = ... }.
    env.GetNumLootItems = function() return #c.loot end
    env.GetLootSlotLink = function(slot)
        local s = c.loot[slot]
        return s[1] and ("|Hitem:" .. s[1] .. "::|h[" .. (s.name or "m") .. "]|h") or nil
    end
    env.GetLootSlotType = function(slot) return c.loot[slot].coin and 2 or 1 end
    env.GetLootSlotInfo = function(slot)
        local s = c.loot[slot]
        return 1, s.coin or "m", s[2] or 0, nil, 1, false, s.quest == true
    end
    env.GetLootSourceInfo = function(slot)   -- nothing: this client names no source
        local s = c.loot[slot]
        if s.from then
            return unpack(s.from, 1, s.from.n or #s.from)
        end
        return c.lootSource, c.lootSource and (s[2] or 1) or nil
    end
    -- The quest log: c.quests = { { id, objectives = { { text, type, finished } } } }, after a header line.
    env.C_QuestLog = {
        GetNumQuestLogEntries = function() return #c.quests + 1 end,
        GetInfo = function(index)
            local quest = c.quests[index - 1]
            return quest and { questID = quest.id, isHeader = false } or { isHeader = true }
        end,
        GetQuestObjectives = function(id)
            for _, quest in ipairs(c.quests) do
                if quest.id == id then return quest.objectives end
            end
        end,
    }
    env.C_Spell = { GetSpellName = function(id)
        return ({ [2575] = "Minage", [2576] = "Minage", [2366] = "Cueillette", [3570] = "Cueillette", [585] = "Châtiment",
            [8613] = "Dépeçage", [8617] = "Dépeçage", [921] = "Vol à la tire" })[id]
    end }
    env.C_Map = {
        GetBestMapForUnit = function() return c.place and c.place[1] end,
        GetPlayerMapPosition = function(map)
            if c.place and c.place[1] == map and c.place[2] then
                return { GetXY = function() return c.place[2], c.place[3] end }
            end
        end,
    }

    function c.fire(event, ...)
        for _, frame in ipairs(c.frames) do
            if frame.events[event] and frame.handler then
                frame.handler(frame, event, ...)
            end
        end
    end
    function c.load(saved)
        c.frames, c.ns, c.texts, c.named, c.messages, c.icon, c.broker, c.options = {}, {}, {}, {}, nil, nil, nil, nil
        c.dropdown, c.buttons = nil, {}
        env.RookieLedgerDB = saved
        for _, file in ipairs(FILES) do
            local chunk = assert(loadfile(ADDON_DIR .. "/" .. file))
            setfenv(chunk, env)
            chunk("RookieLedger", c.ns)
        end
        c.fire("ADDON_LOADED", "RookieLedger")
        c.fire("PLAYER_LOGIN")
        c.db = env.RookieLedgerDB
    end
    clients[#clients + 1] = c
    return c
end

-- Recording ------------------------------------------------------------------

local A = newClient("A")
A.profs = { { line = 333, rank = 125 }, { line = 197, rank = 90 } }
A.recipes = {
    [7421] = { line = 333, at = { 130, 150, 170 } },   -- orange at 125
    [7418] = { line = 333, at = { 100, 126, 140 } },   -- yellow at 125, green at 126
    [7443] = { line = 333, at = { 70, 90, 110 } },     -- grey
    [2387] = { line = 197, at = { 80, 95, 110 } },     -- tailoring, yellow at 90
}
A.load(nil)
check("token is 32 hex digits", A.db.token:match("^%x+$") and #A.db.token == 32, A.db.token)
check("id is 8 hex digits", A.db.id:match("^%x+$") and #A.db.id == 8, A.db.id)
check("a copy of the repository says it is one", A.ns.version == "dev" and A.printed[1]:find("dev chargé. /ledger", 1, true), A.printed[1])
check("first login explains the token", #A.printed == 3 and A.printed[3]:find("/ledger token", 1, true))

A.window = 333
A.fire("TRADE_SKILL_SHOW")
run(2)
local own = A.db.own
check("colours of the open profession", own.c[7421] and own.c[7421][2] == 125 and own.c[7421][3] == 125
    and own.c[7418][4] == 125 and own.c[7443][8] == 125 and own.c[7421][1] == 333)
check("the other profession is not read", own.c[2387] == nil)
local revAfterScan = own.rev
A.fire("TRADE_SKILL_LIST_UPDATE")
run(2)
check("a scan that learns nothing changes nothing", own.rev == revAfterScan)

-- A craft that gives a point, then the window follows the new skill.
A.fire("UNIT_SPELLCAST_START", "player", "cast", 7418)
run(3)
A.profs[1].rank = 126
A.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 7418)
A.fire("SKILL_LINES_CHANGED")
A.fire("TRADE_SKILL_LIST_UPDATE")
run(4)
check("craft with a skill-up", own.s["7418:125:1"] and own.s["7418:125:1"][1] == 1 and own.s["7418:125:1"][2] == 1)
check("colours at the new skill", own.c[7418][4] == 125 and own.c[7418][5] == 125 and own.c[7418][6] == 126
    and own.c[7421][3] == 126)

-- Two crafts in a row without a point, the second resolved by the timer.
for _ = 1, 2 do
    A.fire("UNIT_SPELLCAST_START", "player", "cast", 7418)
    run(3)
    A.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 7418)
    run(0.3)
end
run(3)
check("crafts without a skill-up", own.s["7418:126:2"] and own.s["7418:126:2"][1] == 2 and own.s["7418:126:2"][2] == 0)

-- An interrupted craft and a spell that is no recipe leave no trace.
A.fire("UNIT_SPELLCAST_START", "player", "cast", 7421)
A.fire("UNIT_SPELLCAST_INTERRUPTED", "player", "cast", 7421)
A.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 585)
run(3)
check("interrupted craft is not counted", own.s["7421:126:0"] == nil)

-- A disenchant: the cape leaves the bags, the loot window holds dust and essence.
A.items = { [2584] = { q = 2, l = 16, k = 4 }, [6337] = { q = 2, l = 20, k = 4 } }
A.bags = { [1] = 2584, [2] = 2584, [5] = 6337 }
A.fire("UNIT_SPELLCAST_START", "player", "cast", 13262)
run(3)
A.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 13262)
A.loot = { { 10940, 2 }, { 10939, 1 } }
A.fire("LOOT_READY")
A.fire("BAG_UPDATE_DELAYED")
check("no result before the item has left the bags", own.d[2584] == nil)
A.bags[2] = nil
A.fire("BAG_UPDATE_DELAYED")
local cape = own.d[2584]
check("disenchant result", cape and cape.n == 1 and cape.l == 16 and cape.q == 2 and cape.k == 4
    and cape.m[10940][1] == 2 and cape.m[10940][2] == 1 and cape.m[10939][1] == 1)
A.loot = {}

-- Two items leaving during one cast: no telling which was disenchanted.
A.fire("UNIT_SPELLCAST_START", "player", "cast", 13262)
A.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 13262)
A.loot = { { 10940, 1 } }
A.fire("LOOT_READY")
A.bags = {}
A.fire("BAG_UPDATE_DELAYED")
check("ambiguous disenchant is dropped", own.d[2584].n == 1 and own.d[6337] == nil)
A.loot = {}

-- A disenchant whose result never showed in a loot window does not take the next loot window, a corpse's, for its own.
A.bags = { [1] = 6337 }
A.fire("UNIT_SPELLCAST_START", "player", "cast", 13262)
A.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 13262)
A.bags = {}
A.fire("BAG_UPDATE_DELAYED")
run(30)
A.loot = { { 2589, 2 } }
A.fire("LOOT_READY")
check("a later loot window is not a disenchant result", own.d[6337] == nil)
A.loot = {}

-- A second attempt the game refuses during the cast (its own cast id, the same spell) does not cancel the first.
A.bags = { [1] = 6337 }
A.fire("UNIT_SPELLCAST_START", "player", "cast-1", 13262)
A.fire("UNIT_SPELLCAST_FAILED", "player", "cast-2", 13262)
A.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-1", 13262)
A.loot = { { 10940, 3 } }
A.fire("LOOT_READY")
A.bags = {}
A.fire("BAG_UPDATE_DELAYED")
check("a refused second attempt does not drop the disenchant", own.d[6337] and own.d[6337].n == 1 and own.d[6337].m[10940][1] == 3)
A.loot = {}
A.fire("UNIT_SPELLCAST_START", "player", "cast-3", 7418)
A.fire("UNIT_SPELLCAST_FAILED", "player", "cast-4", 7418)
run(3)
A.profs[1].rank = 127
A.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-3", 7418)
run(3)
check("a refused second attempt does not restart the craft", own.s["7418:126:2"][1] == 3 and own.s["7418:126:2"][2] == 1
    and own.s["7418:127:2"] == nil)
A.fire("UNIT_SPELLCAST_START", "player", "cast-5", 7418)
A.fire("UNIT_SPELLCAST_INTERRUPTED", "player", "cast-5", 7418)
A.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 585)
run(3)
check("an interrupted craft is still dropped", own.s["7418:127:2"] == nil)

-- A queue as the client runs it: a craft's point comes after the next craft has started. Each craft is counted at
-- the skill it was made at, with its own point; then the same with casts shorter than the wait for the points.
local function countedAt(skill)
    for colour = 0, 3 do
        local counts = own.s["7418:" .. skill .. ":" .. colour]
        if counts then return counts[1], counts[2] end
    end
end
for round, cast in ipairs({ 2, 0.3 }) do
    local first = A.profs[1].rank
    for n = 1, 3 do
        A.fire("UNIT_SPELLCAST_START", "player", "queue-" .. round .. n, 7418)
        if n > 1 then
            A.profs[1].rank = first + n - 1   -- the point of the craft before
            A.fire("SKILL_LINES_CHANGED")
        end
        run(cast)
        A.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "queue-" .. round .. n, 7418)
    end
    A.profs[1].rank = first + 3
    A.fire("SKILL_LINES_CHANGED")
    run(3)
    for n = 0, 2 do
        local crafts, ups = countedAt(first + n)
        check("craft " .. n + 1 .. " of a queue has its own point (casts of " .. cast .. " s)", crafts == 1 and ups == 1)
    end
    check("a queue counts no craft at the skill it ends at (casts of " .. cast .. " s)", countedAt(first + 3) == nil)
end

-- A corpse looted while the disenchant is still being cast is not its result, whether the client names the loot's
-- source or not.
for _, named in ipairs({ true, false }) do
    local item = named and 7001 or 7002
    A.items[item] = { q = 2, l = 22, k = 4 }
    A.bags = { [1] = item }
    A.fire("UNIT_SPELLCAST_START", "player", "cast-6", 13262)
    run(1)
    A.loot, A.lootSource = { { 2589, 2 } }, named and "Creature-0-4444-0-1-299-0000000001" or nil
    A.fire("LOOT_READY")
    run(2)
    A.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-6", 13262)
    A.loot, A.lootSource = { { 10940, 2 } }, named and "Item-4444-0-4000000000000001" or nil
    A.fire("LOOT_READY")
    A.bags = {}
    A.fire("BAG_UPDATE_DELAYED")
    local entry = own.d[item]
    check("a corpse looted during the cast is not the result (source " .. (named and "named" or "not named") .. ")",
        entry and entry.n == 1 and entry.m[10940] and entry.m[10940][1] == 2 and entry.m[2589] == nil)
    A.loot, A.lootSource = {}, nil
end
-- A result window that opens a moment before the cast is reported as done still counts.
A.items[7003] = { q = 2, l = 22, k = 4 }
A.bags = { [1] = 7003 }
A.fire("UNIT_SPELLCAST_START", "player", "cast-7", 13262)
run(3)
A.loot = { { 10940, 1 } }
A.fire("LOOT_READY")
run(0.2)
A.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-7", 13262)
A.bags = {}
A.fire("BAG_UPDATE_DELAYED")
check("a result window just before the cast's end counts", own.d[7003] and own.d[7003].m[10940][1] == 1)
A.loot = {}

-- Gathering: the vein the loot window names, what it gave and where the player stood.
local function gatherOnce(spell, node, loot, place)
    A.place = place
    A.fire("UNIT_SPELLCAST_START", "player", "gather", spell)
    run(2)
    A.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "gather", spell)
    A.loot, A.lootSource = loot, node and ("GameObject-0-4444-0-1-" .. node .. "-00006A2B11")
    A.fire("LOOT_READY")
    A.fire("LOOT_READY")   -- the game may say it twice for one window
    A.fire("LOOT_CLOSED")
    A.loot, A.lootSource = {}, nil
    run(1)
end
gatherOnce(2575, 1731, { { 2770, 3 }, { 2835, 1 } }, { 1429, 0.4321, 0.6543 })
local vein = own.g[1731]
check("a mined vein: yield and place", vein and vein.k == 1 and vein.n == 1 and vein.m[2770][1] == 3 and vein.m[2770][2] == 1
    and vein.m[2835][1] == 1 and vein.p["1429:432:654"] == 1)
gatherOnce(2576, 1731, { { 2770, 2 } }, { 1429, 0.4350, 0.6510 })   -- a higher rank, a step to the side
check("the same vein again is the same place", vein.n == 2 and vein.m[2770][1] == 5 and vein.m[2835][2] == 1
    and vein.p["1429:432:654"] == 2 and next(vein.p, next(vein.p)) == nil)
gatherOnce(2575, 1731, { { 2770, 1 } }, { 1429, 0.6000, 0.2000 })
check("another vein of the kind is another place", vein.n == 3 and vein.p["1429:600:200"] == 1)
gatherOnce(3570, 1618, { { 2447, 2 } }, { 1429, 0.1, 0.1 })
check("a herb gathered with a higher rank", own.g[1618] and own.g[1618].k == 2 and own.g[1618].m[2447][1] == 2)
gatherOnce(2575, 1731, { { 2770, 1 } }, nil)
check("a gather without a position still counts", vein.n == 4 and vein.p["1429:432:654"] == 2)
local revAfterGather = own.rev
gatherOnce(2575, nil, { { 2770, 1 } }, { 1429, 0.5, 0.5 })   -- a loot window that names no vein
A.loot, A.lootSource = { { 2589, 2 } }, "Item-4444-0-4000000000000002"
A.fire("LOOT_READY")
A.fire("LOOT_CLOSED")
A.loot, A.lootSource = {}, nil
check("only a loot window that names a vein or herb is a gather", own.rev == revAfterGather and vein.n == 4)
A.fire("UNIT_SPELLCAST_START", "player", "gather-2", 2575)
A.fire("UNIT_SPELLCAST_INTERRUPTED", "player", "gather-2", 2575)
A.loot, A.lootSource = { { 2770, 1 } }, "GameObject-0-4444-0-1-1731-00006A2B11"
A.fire("LOOT_READY")
A.loot, A.lootSource = {}, nil
check("an interrupted gather records nothing", vein.n == 4)

-- Monster loot: every corpse a loot window names, with its items of every quality and its coin.
run(15)   -- past the last gathering cast
A.fire("LOOT_CLOSED")   -- the windows of the checks above were never closed
local function corpse(creature, spawn) return "Creature-0-4444-0-1-" .. creature .. "-" .. spawn end
local function lootWindow(slots)
    A.loot = slots
    A.fire("LOOT_READY")
    A.fire("LOOT_READY")
    A.fire("LOOT_CLOSED")
    A.loot = {}
end
A.lootSource = corpse(299, "0000000A01")
A.target, A.targetName = A.lootSource, "Loup"
lootWindow({ { coin = "1 Argent\n20 Cuivre" }, { 2589, 2 }, { 771, 1 }, { 9999, 1, quest = true } })
A.target, A.targetName = nil, nil
local wolf = own.m[299]
local log = A.env.RookieLedgerLocal.log
check("the log tells the corpse by the name of the target, its items as links and its coin", log[#log][2] == "m"
    and log[#log][3] == "Loup : |Hitem:771::|h[m]|h, |Hitem:2589::|h[m]|h x2, 120 cuivre, "
    .. "|Hitem:9999::|h[m]|h (objet de quête)", log[#log][3])
check("a quest item the log names is still not in the record", wolf.i[9999] == nil)
check("a corpse: items of every quality and its coin, no quest item", wolf and wolf.n == 1 and wolf.cn == 1 and wolf.c == 120
    and wolf.i[2589][1] == 2 and wolf.i[2589][2] == 1 and wolf.i[771][1] == 1 and wolf.i[9999] == nil)
lootWindow({ { 771, 1 } })
check("a corpse opened again is not counted twice", wolf.n == 1 and wolf.i[771][1] == 1)
A.lootSource = corpse(299, "0000000A02")
lootWindow({ { 2589, 1 } })
check("a corpse without coin counts as no coin", wolf.n == 2 and wolf.cn == 2 and wolf.c == 120 and wolf.i[2589][2] == 2)
-- One window for three corpses of two kinds: each item goes to the corpse that held it.
A.lootSource = nil
local a, b, k = corpse(299, "0000000A03"), corpse(299, "0000000A04"), corpse(118, "0000000B01")
lootWindow({
    { coin = "3 Argent", from = { a, 100, b, 150, k, 50 } },
    { 2589, 5, from = { a, 2, k, 3 } },
    { 4306, 1, from = { b, 1 } },
})
local kobold = own.m[118]
check("several corpses in one window", wolf.n == 4 and wolf.cn == 4 and wolf.c == 370 and wolf.i[2589][1] == 5
    and wolf.i[2589][2] == 3 and wolf.i[4306][1] == 1 and kobold.n == 1 and kobold.c == 50 and kobold.i[2589][1] == 3)
-- Shares of the coin that do not add up to what the window shows: the coin of these corpses is unknown.
local d, e = corpse(118, "0000000B02"), corpse(118, "0000000B03")
lootWindow({ { coin = "2 Argent", from = { d, 1, e, 1 } }, { 2589, 2, from = { d, 1, e, 1 } } })
check("coin that cannot be told apart is left unknown", kobold.n == 3 and kobold.cn == 1 and kobold.c == 50
    and kobold.i[2589][2] == 3)
local revAfterLoot = own.rev
A.grouped = true
A.lootSource = corpse(118, "0000000B04")
lootWindow({ { 2589, 1 } })
A.grouped = false
check("nothing is counted in a group", own.rev == revAfterLoot and kobold.n == 3)
A.lootSource = "GameObject-0-4444-0-1-2843-00006A2B77"   -- a chest
lootWindow({ { 2589, 1 } })
A.lootSource = nil   -- a window that names no source
lootWindow({ { 2589, 1 } })
check("a chest or an unnamed source is not a corpse", own.rev == revAfterLoot)
-- Skinning and picking a pocket open a window that names the creature too: neither holds what it dropped.
A.lootSource = corpse(118, "0000000B05")
A.fire("UNIT_SPELLCAST_START", "player", "skin", 8617)
run(2)
A.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "skin", 8617)
lootWindow({ { 2318, 1 } })
A.lootSource = corpse(40, "0000000C01")
A.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "pick", 921)
lootWindow({ { coin = "5 Cuivre" } })
check("skinning and picking a pocket are not looting a corpse", own.rev == revAfterLoot and kobold.n == 3 and own.m[40] == nil)
-- The same creature once dead, in a window announced before its content is there. Coin whose text is not read to
-- the end is unknown, and an item the client gives no quantity of was held once.
A.loot = {}
A.fire("LOOT_READY")
lootWindow({ { coin = "1 Argent\n3 Bronze" }, { 4306, 0, from = { A.lootSource } } })
local thief = own.m[40]
check("a creature whose pocket was picked still counts once dead", thief and thief.n == 1)
check("coin read in part is left unknown", thief and thief.cn == 0 and thief.c == 0)
check("an item without a quantity was held once", thief and thief.i[4306][1] == 1 and thief.i[4306][2] == 1)
-- A skinning cast given up takes no window with it: the corpse looted next is read. Some monsters are named as
-- vehicles, and some locales write coin with a plural mark that holds a digit of its own.
A.fire("UNIT_SPELLCAST_START", "player", "skin-2", 8613)
A.fire("UNIT_SPELLCAST_INTERRUPTED", "player", "skin-2", 8613)
A.lootSource = "Vehicle-0-4444-0-1-777-0000000D01"
A.env.COPPER_AMOUNT = "%d |4pièce:pièces; de cuivre"
lootWindow({ { coin = "7 |4pièce:pièces; de cuivre" } })
A.env.COPPER_AMOUNT = "%d Cuivre"
local rider = own.m[777]
check("a corpse looted after a skinning cast given up is read, a vehicle's too", rider and rider.n == 1)
check("coin written with a plural mark is read", rider and rider.cn == 1 and rider.c == 7)
-- A skinning window that opens before the cast is reported as done: the report that follows announces no other
-- window, and the corpse looted next is read.
run(15)
A.lootSource = corpse(525, "0000000E01")
A.fire("UNIT_SPELLCAST_START", "player", "skin-3", 8613)
run(2)
lootWindow({ { 2318, 1 } })
A.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "skin-3", 8613)
A.lootSource = corpse(525, "0000000E02")
lootWindow({ { 2589, 1 } })
local boar = own.m[525]
check("a corpse looted right after a skinning window that came early is read", boar and boar.n == 1 and boar.i[2318] == nil)
-- The hide left in the window and taken later, without a cast: still not a drop.
run(15)
A.lootSource = corpse(525, "0000000E01")
lootWindow({ { 2318, 1 } })
check("a skinned corpse opened again is not looted either", boar.n == 1 and boar.i[2318] == nil)
-- A cast the connection held up: the window follows its end, however long ago it started.
A.lootSource = corpse(525, "0000000E03")
A.fire("UNIT_SPELLCAST_START", "player", "skin-4", 8613)
run(12)
A.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "skin-4", 8613)
lootWindow({ { 2318, 1 } })
check("a skinning window after a held-up cast is not a corpse's", boar.n == 1 and boar.i[2318] == nil)
-- A slot of two corpses whose shares the client does not tell: what the window holds is counted once.
run(15)
lootWindow({ { 2589, 5, from = { corpse(525, "0000000E04"), nil, corpse(525, "0000000E05"), nil, n = 4 } } })
check("a slot shared without shares is split, not doubled", boar.n == 3 and boar.i[2589][1] == 6 and boar.i[2589][2] == 3)

-- A skill bonus stops the recording for that profession.
A.window = 197
A.profs[2].bonus = 15
A.fire("TRADE_SKILL_SHOW")
run(2)
check("no colours under a skill bonus", own.c[2387] == nil)
A.profs[2].bonus = 0
A.fire("TRADE_SKILL_LIST_UPDATE")
run(2)
check("colours once the bonus is gone", own.c[2387] and own.c[2387][4] == 90)

-- A reload keeps token, id and data, and the corpses already counted: one left half looted is not a new one.
run(15)
A.lootSource = corpse(3100, "0000000F01")
lootWindow({ { coin = "4 Cuivre" }, { 2589, 2 } })
local ogre = own.m[3100]
check("the session counts what was recorded since login", A.ns.session.m == 13 and A.ns.session.g == 5
    and A.ns.session.d == 5 and A.ns.session.s == 10 and A.ns.session.c == 13, ("m %s g %s d %s s %s c %s"):format(
    tostring(A.ns.session.m), tostring(A.ns.session.g), tostring(A.ns.session.d), tostring(A.ns.session.s), tostring(A.ns.session.c)))
check("the log names a corpse nobody points at by its id", #log == 38
    and log[38][3] == "créature 3100 : |Hitem:2589::|h[m]|h x2, 4 cuivre", #log .. " " .. log[#log][3])
local token, id, seenUpTo = A.db.token, A.db.id, A.db.own.c[7421][3]
A.version, A.printed = "v0.2.1", {}
A.load(A.db)
check("a reload keeps the token and the record", A.db.token == token and A.db.id == id and A.db.own.c[7421][3] == seenUpTo)
check("every login says the version, and nothing more once the token is made", #A.printed == 1
    and A.printed[1]:find("v0.2.1 chargé. /ledger pour le détail.", 1, true), A.printed[1])
check("a reload keeps the log and starts the session's counts again", #A.env.RookieLedgerLocal.log == 38
    and A.env.RookieLedgerLocal.log[38][3]:find("créature 3100", 1, true) and next(A.ns.session) == nil)
A.version = nil
A.load(A.db)
check("a client that tells no version is a copy of the repository too", A.ns.version == "dev")
A.version = "v0.2.1"
lootWindow({ { 2589, 1 } })
check("a corpse opened again after a reload is not counted twice", ogre.n == 1 and ogre.i[2589][1] == 2)
A.lootSource = corpse(525, "0000000E01")
lootWindow({ { 2318, 1 } })
check("a skinned corpse stays one after a reload", boar.n == 3 and boar.i[2318] == nil)
local ring = A.env.RookieLedgerLocal
check("the corpses counted are kept per character, in the order they came", ring.v == 1
    and ring.seen[ring.next - 1] == corpse(3100, "0000000F01") and ring.seen[1] == corpse(299, "0000000A01"))
-- A file of this character that is lost or damaged costs nothing but that memory.
A.env.RookieLedgerLocal = { seen = { 5, "x", false, corpse(3100, "0000000F01") }, next = "z" }
A.load(A.db)
A.lootSource = corpse(3100, "0000000F02")
lootWindow({ { 2589, 1 } })
A.lootSource = corpse(3100, "0000000F01")
lootWindow({ { 2589, 1 } })
ring = A.env.RookieLedgerLocal
check("a damaged file of the character is put right", ogre.n == 2 and ring.seen[1] == "x"
    and ring.seen[3] == corpse(3100, "0000000F02") and ring.next == 4)
A.env.RookieLedgerLocal = nil
A.load(A.db)
check("a lost file of the character is made again", type(A.env.RookieLedgerLocal.seen) == "table"
    and A.env.RookieLedgerLocal.next == 1)
A.lootSource = nil
A.db.v = 99
A.load(A.db)
check("another saved format keeps the token and the record", A.db.token == token and A.db.id == id
    and A.db.own.c[7421][3] == seenUpTo and A.db.v == 1)
A.ns.Command("token")
check("/ledger token shows the popup", A.popup == "ROOKIELEDGER_TOKEN")
-- What a version with guild sync kept is dropped from the saved table.
A.db.peers, A.db.sync, A.db.own.lr, A.db.own.lr0, A.db.own.hold = { deadbeef = { rev = 1 } }, true, { c7421 = 3 }, 2, {}
A.load(A.db)
check("leftovers of guild sync are removed", A.db.peers == nil and A.db.sync == nil and A.db.own.lr == nil
    and A.db.own.lr0 == nil and A.db.own.hold == nil and A.db.own.c[7421][3] == seenUpTo)
A.ns.Command("")
check("/ledger counts everything", A.printed[#A.printed]:find("5 filons et plantes récoltés, 14 cadavres fouillés", 1, true), A.printed[#A.printed])

-- The window, the minimap button and the options page ----------------------------

local function text(wanted)
    for _, t in ipairs(A.texts) do
        if t.text == wanted then return true end
    end
end
check("the minimap button is registered with the character's own table, the options page with the game",
    A.icon and A.icon.db == A.env.RookieLedgerLocal.minimap and A.icon.shown and A.options == "RookieLedger")
check("no window before it is asked for", A.named.RookieLedgerWindow == nil)
A.broker.OnClick(nil, "LeftButton")
local shown = A.named.RookieLedgerWindow
check("a left click on the minimap button opens the window", shown and shown:IsShown() and text("Cadavres fouillés")
    and text("14") and text("v0.2.1"))
-- The file of this character was lost further up, and its log with it.
check("an empty log says so", #A.messages.lines == 1 and A.messages.lines[1]:find("Rien d'enregistré", 1, true),
    A.messages.lines[1])
A.lootSource = corpse(4000, "0000001001")
A.target, A.targetName = A.lootSource, "Ogre"
lootWindow({ { 4306, 1 } })
A.target, A.targetName, A.lootSource = nil, nil, nil
check("what is recorded while the window is open shows at once", A.messages.lines[#A.messages.lines]:find("Ogre : ", 1, true)
    and text("15") and text("1"), A.messages.lines[#A.messages.lines])
A.ns.Command("show")
check("/ledger show closes the open window", not shown:IsShown())
A.ns.Command("fenêtre")
check("and opens it again", shown:IsShown())
A.popup, A.opened = nil, nil
A.broker.OnClick(nil, "RightButton")
check("a right click on the minimap button opens the options, and shows no token", A.opened == "RookieLedger"
    and A.popup == nil)
A.opened, A.fighting = nil, true
A.broker.OnClick(nil, "RightButton")
A.fighting = nil
check("which the game may refuse in a fight, without a word", A.opened == nil)
A.ns.Command("token")
check("/ledger token still shows the token", A.popup == "ROOKIELEDGER_TOKEN")
local tip = { lines = {} }
function tip:AddLine(line) self.lines[#self.lines + 1] = line end
function tip:AddDoubleLine(left, right) self.lines[#self.lines + 1] = left .. " = " .. right end
A.broker.OnTooltipShow(tip)
check("the button's tooltip says what each click does", tip.lines[#tip.lines] == "Clic droit : options"
    and tip.lines[#tip.lines - 1] == "Clic gauche : fenêtre", tip.lines[#tip.lines])
local openToCategory = A.env.Settings.OpenToCategory
A.env.Settings.OpenToCategory = nil
local bare = { lines = {} }
bare.AddLine, bare.AddDoubleLine = tip.AddLine, tip.AddDoubleLine
A.broker.OnTooltipShow(bare)
A.broker.OnClick(nil, "RightButton")
check("a client that cannot open the options from an addon promises no right click",
    bare.lines[#bare.lines] == "Clic gauche : fenêtre" and A.opened == nil, bare.lines[#bare.lines])
A.env.Settings.OpenToCategory = openToCategory
check("the button's tooltip gives the counts of the session and in total",
    table.concat(tip.lines, "\n"):find("Cadavres fouillés = 1 / 15", 1, true), table.concat(tip.lines, " | "))
A.ns.Command("minimap")
check("/ledger minimap hides the button and remembers it", not A.icon.shown and A.env.RookieLedgerLocal.minimap.hide == true)
A.load(A.db)
check("a hidden button stays hidden after a reload", A.icon and not A.icon.shown)
A.ns.Command("minimap")
check("/ledger minimap shows it again", A.icon.shown and A.env.RookieLedgerLocal.minimap.hide == nil)
-- A copy of the repository has no libraries: no button, and everything else as before.
A.nolibs = true
A.load(A.db)
A.ns.Command("minimap")
check("without the libraries there is no button, and /ledger minimap says so", A.icon == nil
    and A.printed[#A.printed]:find("bibliothèques", 1, true), A.printed[#A.printed])
A.ns.Command("show")
A.lootSource = corpse(4000, "0000001002")
lootWindow({ { 4306, 1 } })
A.lootSource = nil
check("the window and the recording work without them", A.named.RookieLedgerWindow:IsShown() and A.db.own.m[4000].n == 2
    and A.messages.lines[#A.messages.lines]:find("créature 4000", 1, true))
A.nolibs = nil
for i = 1, 60 do
    A.ns.Log("c", "line " .. i, 0)
end
log = A.env.RookieLedgerLocal.log
check("the log keeps the last 50", #log == 50 and log[1][3] == "line 11" and log[50][3] == "line 60"
    and #A.messages.lines == 50, #log)
local failure
for _, line in ipairs(A.printed) do
    failure = failure or (line:find("%.lua:%d") and line)
end
check("no part of the interface failed", not failure, failure)

-- Quest items ------------------------------------------------------------------
-- A quest item drops only for who has the quest: it is counted against the corpses looted while the quest wanted it.

local blood = { 2858, 1, quest = true, name = "Sang de sombredogue" }
local hound = 0
local function houndCorpse(slots)
    hound = hound + 1
    A.lootSource = corpse(5000, ("00000020%02d"):format(hound))
    lootWindow(slots)
    A.lootSource = nil
end
local function wants(text, finished) return { text = text, type = "item", finished = finished or false } end
local q = A.db.own.q
houndCorpse({ blood, { 2589, 1 } })
check("a quest item nobody asks for is not counted", next(q) == nil and A.db.own.m[5000].i[2858] == nil)
-- The French client puts a no-break space before the colon; another objective starts with the same words.
A.quests = {
    { id = 300, objectives = { { text = "Loup tué : 0/8", type = "monster", finished = false } } },
    { id = 367, objectives = { wants("Sang de sombredogue épais : 0/2"), wants("Sang de sombredogue\194\160: 1/5") } },
}
houndCorpse({ blood })
local entry = q["5000:2858"]
check("the first corpse that shows it tells which quest wants it, and is not counted itself", entry and entry.q == 367
    and entry.j == 2 and entry.n == 0 and entry.k == 0 and entry.t == 0)
houndCorpse({ { 2589, 1 } })
check("a corpse without it is a chance missed", entry.n == 1 and entry.k == 0)
houndCorpse({ { 2858, 2, quest = true, name = "Sang de sombredogue" }, { 2589, 1 } })
check("a corpse with it is a chance taken", entry.n == 2 and entry.k == 1 and entry.t == 2
    and A.db.own.m[5000].i[2858] == nil)
local revBefore = A.db.own.rev
A.lootSource = corpse(5000, ("00000020%02d"):format(hound))
lootWindow({ blood })
check("the same corpse opened again is no new chance", entry.n == 2 and A.db.own.rev == revBefore)
A.load(A.db)
entry = A.db.own.q["5000:2858"]
houndCorpse({ { 2589, 1 } })
check("the quest items known are counted on after a reload", entry.n == 3 and entry.k == 1)
A.grouped = true
houndCorpse({ blood })
A.grouped = false
check("nothing of it is counted in a group", entry.n == 3)
A.quests[2].objectives[2].finished = true
houndCorpse({ blood })
houndCorpse({ { 2589, 1 } })
check("once the objective is reached, corpses are chances no more", entry.n == 3 and entry.k == 1)
A.quests = {}
houndCorpse({ { 2589, 1 } })
check("nor without the quest", entry.n == 3)
-- Two objectives could be meant: the item is left alone.
A.quests = { { id = 400, objectives = { wants("Griffe : 0/3") } }, { id = 401, objectives = { wants("Griffe: 1/4") } } }
houndCorpse({ { 2859, 1, quest = true, name = "Griffe" } })
check("an item two quests ask for by the same name is not tied to either", A.db.own.q["5000:2859"] == nil)
A.quests = { { id = 402, objectives = { wants("Griffe putride : 0/7") } } }
houndCorpse({ { 2859, 1, quest = true, name = "Griffe" } })
check("a name that only starts another item's is not that item", A.db.own.q["5000:2859"] == nil)
A.quests = {}

-- Where a corpse was looted: the cell of the map the player stood in.
local placeBefore = A.place
A.place = { 1429, 0.4321, 0.6549 }
A.lootSource = corpse(7000, "0000003001")
lootWindow({ { 2589, 1 } })
local bear = A.db.own.m[7000]
check("a corpse is placed in the cell of the map where it was looted", bear.n == 1 and bear.p["1429:430:655"] == 1)
A.place = { 1429, 0.4312, 0.6561 }
A.lootSource = corpse(7000, "0000003002")
lootWindow({ { 2589, 1 } })
check("a corpse looted a few steps away is in the same cell", bear.n == 2 and bear.p["1429:430:655"] == 2
    and next(bear.p, next(bear.p)) == nil)
A.place = { 1429, 0.999, 0 }
A.lootSource = corpse(7000, "0000003003")
lootWindow({ { 2589, 1 } })
check("the edge of the map is a cell too", bear.p["1429:1000:0"] == 1)
A.place = nil
A.lootSource = corpse(7000, "0000003004")
lootWindow({ { 2589, 1 } })
check("a corpse looted where the client gives no position still counts", bear.n == 4 and bear.p["1429:430:655"] == 2)
A.db.own.m[7001] = { n = 1, cn = 1, c = 3, i = {} }   -- as a version before places wrote it
A.place = { 1437, 0.2, 0.3 }
A.lootSource = corpse(7001, "0000003005")
lootWindow({ { 2589, 1 } })
check("an entry of before places takes them from now on", A.db.own.m[7001].n == 2 and A.db.own.m[7001].p["1437:200:300"] == 1)
A.place = placeBefore

-- How long the record took to make: the time between its changes, as far as it is play.
local own, before = A.db.own, A.db.own.a
check("the record tells when it began and how long it took", own.f >= 1794800000 and own.f <= own.t
    and before >= 60, own.f .. " " .. before)
run(100)
A.lootSource = corpse(7000, "0000003006")
lootWindow({ { 2589, 1 } })
check("a change counts for the time since the one before", own.a == before + 100, own.a - before)
run(1000)
A.lootSource = corpse(7000, "0000003007")
lootWindow({ { 2589, 1 } })
check("but not for the time spent away", own.a == before + 400, own.a - before)

-- The monster tooltip ------------------------------------------------------------
-- Under a monster's tooltip: what this account's record holds of it.

local function tipOf(creature, spawn)
    local tip = A.env.GameTooltip
    tip.lines = {}
    A.mouseover = creature and corpse(creature, spawn or "0000009901") or "Player-6941-B"
    tip.scripts.OnTooltipCleared(tip)
    tip.scripts.OnTooltipSetUnit(tip)
    return tip.lines
end
A.itemInfo = { [2589] = { "Étoffe de lin", 1 }, [771] = { "Défense ébréchée", 0 }, [2858] = { "Sang de sombredogue", 1 } }
A.load(A.db)
local tipLines = tipOf(299)
check("a monster's tooltip tells how many were looted and what they held, the most frequent first",
    tipLines[1] == " " and tipLines[2] == "|cffe6b422RookieLedger|r = |cff8a8a8afouillé 4×|r"
    and tipLines[3] == "  |cffffffffÉtoffe de lin|r = 3/4|cff8a8a8a x1.7|r"
    and tipLines[4] == "  |cff9d9d9dDéfense ébréchée|r = 1/4" and tipLines[5] == "  |cff8a8a8aobjet 4306|r = 1/4"
    and tipLines[6] == "  Pièces = 93 cuivre" and #tipLines == 6, table.concat(tipLines, " | "))
check("a monster never looted, and a player, get nothing", #tipOf(31337) == 0 and #tipOf(nil) == 0)
tipLines = tipOf(5000)
check("a quest item is told against the corpses looted while the quest wanted it",
    tipLines[#tipLines] == "  |cffffffffSang de sombredogue|r|cff8a8a8a (quête)|r = 1/3", table.concat(tipLines, " | "))
-- From ten corpses on a rate is a percentage.
for i = 1, 10 do
    A.lootSource = corpse(6000, ("00000030%02d"):format(i))
    lootWindow(i <= 5 and { { 2589, 1 }, { 771, 1 } } or { { 2589, 1 } })
end
A.lootSource = nil
tipLines = tipOf(6000)
check("from ten corpses on, rates are percentages", tipLines[2]:find("fouillé 10×", 1, true)
    and tipLines[3] == "  |cffffffffÉtoffe de lin|r = 100 %" and tipLines[4] == "  |cff9d9d9dDéfense ébréchée|r = 50 %",
    table.concat(tipLines, " | "))
-- The settings: the quality from which items show, and the switch.
check("the options page offers the game's drop-down with the qualities", A.dropdown and A.dropdown.menu)
local radios = {}
A.dropdown.menu(nil, { CreateRadio = function(_, label, isSelected, select, data)
    radios[#radios + 1] = { label = label, isSelected = isSelected, select = select, data = data }
end })
check("from all up to epic, all chosen at first", #radios == 5 and radios[1].label == "Tout" and radios[1].isSelected(0)
    and radios[3].label == "|cff1eff00Inhabituel|r" and radios[5].label == "Épique" and not radios[2].isSelected(1))
radios[2].select(radios[2].data)
tipLines = tipOf(6000)
check("items under the quality asked for are left out, the others stay", #tipLines == 3
    and tipLines[3]:find("Étoffe de lin", 1, true) and A.env.RookieLedgerLocal.tooltip.from == 1, table.concat(tipLines, " | "))
check("an item of unknown quality stays too", table.concat(tipOf(299), " | "):find("objet 4306", 1, true)
    and not table.concat(tipOf(299), " | "):find("Défense", 1, true))
A.ns.Command("tooltip")
check("/ledger tooltip switches it off", #tipOf(6000) == 0 and A.env.RookieLedgerLocal.tooltip.off == true)
A.load(A.db)
check("off and the quality are kept over a reload", #tipOf(6000) == 0 and A.ns.Tooltip.From() == 1)
A.ns.Command("infobulle")
check("and on again", #tipOf(6000) == 3 and A.env.RookieLedgerLocal.tooltip.off == nil)
-- A client without the drop-down gets a button that goes through the qualities.
A.nodropdown = true
A.load(A.db)
local cycle
for _, button in ipairs(A.buttons) do
    if button.text == "Commun" or button.text == "|cffffffffCommun|r" then cycle = button end
end
check("without the drop-down, a button shows the quality chosen", cycle ~= nil)
cycle.scripts.OnClick(cycle)
check("and a click goes to the next one", A.ns.Tooltip.From() == 2 and cycle.text == "|cff1eff00Inhabituel|r", cycle.text)
A.ns.Tooltip.SetFrom(0)
A.nodropdown = nil
A.mouseover = nil

-- The log of groups ---------------------------------------------------------------
-- In a group nothing is counted; what the client tells of loot there is written down, line by line, for study.

local function glog() return A.env.RookieLedgerGroup end
local function gline(back) return glog().l[#glog().l - (back or 0)] end
A.env.RookieLedgerGroup = { v = 1, l = "x" }
A.load(A.db)
check("a damaged log is begun again", glog().v == 1 and glog().n == 0 and #glog().l == 0 and glog().k >= 1794800000)
local mate = "Player-6941-0B0B0B0B"
local dead = corpse(8001, "0000004002")
A.lootSource, A.canLoot, A.money = corpse(8000, "0000004001"), { [dead] = true }, 1000
A.fire("PARTY_KILL", mate, A.lootSource)
lootWindow({ { 2589, 1 } })
A.fire("CHAT_MSG_MONEY", "Vous ramassez 3 Cuivre.")
run(3)
check("nothing is written outside a group", glog().n == 0)
A.grouped, A.party = true, { party1 = mate }
A.fire("GROUP_ROSTER_UPDATE")
A.fire("GROUP_ROSTER_UPDATE")
check("a session's first line tells the client and the addon", glog().n == 2
    and glog().l[1]:match("^%d+%.%d%d S build=70374 version=v0%.2%.1 locale=frFR$"), glog().l[1])
check("the group, its loot method and threshold are written when they change",
    gline():match(" G members=3 raid=0 method=3 threshold=2 instance=none map=%d+$"), gline())
A.fire("PARTY_KILL", mate, dead)
A.fire("UNIT_DIED", dead)
run(3)
check("a death is one line: when, whose kill, and whether the corpse is ours to open", glog().n == 3
    and gline():match(" D c8001%.%x%x%x%x%x%x%x%x %-2%.%d%d by=party1 0%.5=1,1 2%.0=1,1$"), gline())
A.lootSource = dead
A.loot = { { coin = "1 Argent\n4 Cuivre" }, { 2589, 2 }, { 9999, 1, quest = true } }
A.fire("LOOT_READY")
A.fire("LOOT_READY")
check("a loot window is one line: every slot, its quality and the corpse it names", glog().n == 4
    and gline():match(" W method=3 threshold=2 coin=104@c8001%.%x+%*1 i2589x2q1@c8001%.%x+%*2 i9999x1q1Q@c8001%.%x+%*1$"),
    gline())
A.money, A.canLoot[dead] = 1035, false
A.fire("LOOT_CLOSED")
A.loot = {}
run(2)
check("after the window: what the character's coin grew by, and the corpse", glog().n == 5
    and gline():match(" E purse=%+35 c8001%.%x+=0,1$"), gline())
check("in a group the record still counts nothing", A.db.own.m[8001] == nil)
run(5)
A.fire("UNIT_DIED", corpse(8001, "0000004003"))
run(0.2)
A.rolls = { [7] = 4568 }
A.fire("START_LOOT_ROLL", 7, 60000, 3)
check("a roll that starts: its item and the monsters that just died",
    gline():match(" R START_LOOT_ROLL 7,60000,3 item=i4568 info=132089,s,1,2,0,1,1 deaths=c8001%.%x+:%-0%.%d%d$"), gline())
run(3)
A.fire("CHAT_MSG_LOOT", "Zorglub reçoit le butin : |cff1eff00|Hitem:4568::|h[Bâton de Zorglub]|h|rx2.", "Zorglub-Sargeras",
    "", "", "Zorglub", "", 0, 0, "", 0, 0, mate)
check("a chat line about an item: whose, which item, which of the client's texts", gline():match(" L party1 i4568 LOOT_ITEM_MULTIPLE 2$"),
    gline())
A.fire("CHAT_MSG_MONEY", "Votre part du butin est de 35 Cuivre.")
check("a chat line about coin: the amount", gline():match(" M 35 LOOT_MONEY_SPLIT$"), gline())
A.fire("CHAT_MSG_LOOT", "Zorglub a choisi Besoin pour : |Hitem:4568::|h[x]|h", "Zorglub", "", "", "", "", 0, 0, "", 0, 0, "Player-6941-0C0C")
check("a text the client has no format for here, of a player outside the group", gline():match(" L other i4568 %- %-$"), gline())
do
    local all = table.concat(glog().l, "\n")
    check("the log holds no name, and no corpse or player as the game names them", not all:find("Zorglub", 1, true)
        and not all:find("Sargeras", 1, true) and not all:find("Creature-", 1, true) and not all:find("Player-", 1, true))
    check("every line starts with its time", not ("\n" .. all):find("\n[^%d]") and not all:find("[^ -~\n]"))
end
local k, written = glog().k, glog().n
A.load(A.db)
A.fire("LOOT_SLOT_CLEARED", 1)
check("a reload keeps the log and starts a session", glog().k == k and glog().n == written + 3
    and gline(2):find(" S build=", 1, true) and gline(1):find(" G members=3", 1, true) and gline():match(" R LOOT_SLOT_CLEARED 1$"))
A.grouped = false
A.fire("GROUP_ROSTER_UPDATE")
A.fire("LOOT_SLOT_CLEARED", 2)
check("leaving the group is written, and nothing after it", gline():match(" G none$") and glog().n == written + 4)
A.grouped = true
for i = 1, 4100 do
    A.fire("LOOT_SLOT_CLEARED", i)
end
A.grouped, A.party, A.lootSource = false, nil, nil
check("a full log lets its oldest lines go and still counts them", #glog().l <= 4000 and #glog().l > 3000
    and glog().n == written + 4 + 4100 and gline():match(" R LOOT_SLOT_CLEARED 4100$"), #glog().l)

-- Saved-variables layout -------------------------------------------------------

local function dump(value, out, depth)
    if type(value) ~= "table" then
        out[#out + 1] = type(value) == "string" and ("%q"):format(value) or tostring(value)
        return
    end
    out[#out + 1] = "{\n"
    local n = #value
    for i = 1, n do
        dump(value[i], out, depth + 1)
        out[#out + 1] = ", -- [" .. i .. "]\n"
    end
    local keys = {}
    for key in pairs(value) do
        if not (type(key) == "number" and key >= 1 and key <= n and key % 1 == 0) then
            keys[#keys + 1] = key
        end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, key in ipairs(keys) do
        out[#out + 1] = type(key) == "string" and ("[%q] = "):format(key) or ("[" .. key .. "] = ")
        dump(value[key], out, depth + 1)
        out[#out + 1] = ",\n"
    end
    out[#out + 1] = "}"
end

do
    local out = {}
    dump(A.db, out, 0)
    check("the record names no corpse", not table.concat(out):find("Creature-", 1, true))
end
if OUT then
    local out = { "\nRookieLedgerDB = " }
    dump(A.db, out, 0)
    out[#out + 1] = "\nRookieLedgerGroup = "
    dump(A.env.RookieLedgerGroup, out, 0)
    out[#out + 1] = "\n"
    local f = assert(io.open(OUT, "w"))
    f:write(table.concat(out))
    f:close()
    print("wrote " .. OUT)
end
for _, c in ipairs(clients) do
    check(c.name .. " tried to send nothing", not c.sent)
    for _, line in ipairs(c.printed) do
        assert(not line:find(c.db.token, 1, true) or line:find("jeton"), "token printed outside /ledger token")
    end
end
print("all checks passed")
