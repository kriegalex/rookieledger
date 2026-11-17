-- Runs the RookieLedger addon outside the game: a stub of the WoW API with a simulated clock. The stub has no way
-- to send anything: an attempt is an error, and a failed check at the end when the addon caught that error.
--   lua5.1 tests/rookieledger_harness.lua addon/RookieLedger [saved-variables-out.lua]
-- Prints "ok <name>" per check and exits non-zero on the first failure. With a second argument it writes client A's
-- RookieLedgerDB in the layout the game gives a saved-variables file, for the server's parser tests.
local ADDON_DIR, OUT = arg[1], arg[2]
local FILES = { "Core.lua", "Record.lua", "Scan.lua" }

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
    local c = { name = name, online = true, frames = {}, printed = {},
        profs = {}, window = nil, recipes = {}, bags = {}, loot = {}, items = {} }
    local env = setmetatable({}, { __index = _G })
    c.env = env
    env.print = function(text) c.printed[#c.printed + 1] = text end
    env.time = function() return 1794800000 + math.floor(clock) end
    env.GetTime = function() return clock end
    env.GetLocale = function() return "frFR" end
    env.GetBuildInfo = function() return "1.60.1", "70374" end
    env.UnitGUID = function() return "Player-6941-" .. name end
    env.IsInGroup = function() return c.grouped == true end
    env.GOLD_AMOUNT, env.SILVER_AMOUNT, env.COPPER_AMOUNT = "%d Or", "%d Argent", "%d Cuivre"
    env.SlashCmdList, env.StaticPopupDialogs = {}, {}
    env.StaticPopup_Show = function(which) c.popup = which end
    env.CreateFrame = function()
        local frame = { events = {} }
        function frame:RegisterEvent(event) self.events[event] = true end
        function frame:RegisterUnitEvent(event, unit)
            assert(unit == "player", "unit events are asked for the player only")
            self.events[event] = true
        end
        function frame:SetScript(_, handler) self.handler = handler end
        c.frames[#c.frames + 1] = frame
        return frame
    end
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
        return c.loot[slot][1] and ("|Hitem:" .. c.loot[slot][1] .. "::|h[m]|h") or nil
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
        c.frames, c.ns = {}, {}
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
check("first login explains the token", #A.printed == 2)

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
lootWindow({ { coin = "1 Argent\n20 Cuivre" }, { 2589, 2 }, { 771, 1 }, { 9999, 1, quest = true } })
local wolf = own.m[299]
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

-- A reload keeps token, id and data.
local token, id, seenUpTo = A.db.token, A.db.id, A.db.own.c[7421][3]
A.load(A.db)
check("a reload keeps the token and the record", A.db.token == token and A.db.id == id and A.db.own.c[7421][3] == seenUpTo)
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
check("/ledger counts everything", A.printed[#A.printed]:find("5 filons et plantes récoltés, 12 cadavres fouillés", 1, true), A.printed[#A.printed])

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

if OUT then
    local out = { "\nRookieLedgerDB = " }
    dump(A.db, out, 0)
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
