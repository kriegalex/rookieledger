-- Runs the RookieLedger addon outside the game: a stub of the WoW API with a simulated clock, one environment per
-- client and a guild channel that delivers every addon message to every client (the sender included, as in game).
--   lua5.1 tests/rookieledger_harness.lua addon/RookieLedger [saved-variables-out.lua]
-- Prints "ok <name>" per check and exits non-zero on the first failure. With a second argument it writes client A's
-- RookieLedgerDB in the layout the game gives a saved-variables file, for the server's parser tests.
local ADDON_DIR, OUT = arg[1], arg[2]
local FILES = { "Core.lua", "Record.lua", "Scan.lua", "Sync.lua" }

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
    local c = { name = name, online = true, frames = {}, printed = {}, sent = 0,
        profs = {}, window = nil, recipes = {}, bags = {}, loot = {}, items = {} }
    local env = setmetatable({}, { __index = _G })
    c.env = env
    env.print = function(text) c.printed[#c.printed + 1] = text end
    env.time = function() return 1794800000 + math.floor(clock) end
    env.GetTime = function() return clock end
    env.GetLocale = function() return "frFR" end
    env.GetBuildInfo = function() return "1.60.1", "70374" end
    env.UnitGUID = function() return "Player-6941-" .. name end
    env.IsInGuild = function() return true end
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
    env.C_ChatInfo = {
        RegisterAddonMessagePrefix = function() return true end,
        SendAddonMessage = function(prefix, text, channel)
            assert(#text <= 255, "addon message longer than 255 bytes")
            assert(not text:find("%z"), "NUL in an addon message")
            for _, other in ipairs(clients) do
                assert(not (other.db and text:find(other.db.token, 1, true)), "a token in an addon message")
            end
            c.sent = c.sent + 1
            for _, other in ipairs(clients) do
                if other.online then
                    other.fire("CHAT_MSG_ADDON", prefix, text, channel, c.name)
                end
            end
            return 0
        end,
    }
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
    env.GetNumLootItems = function() return #c.loot end
    env.GetLootSlotLink = function(slot) return "|Hitem:" .. c.loot[slot][1] .. "::|h[m]|h" end
    env.GetLootSlotInfo = function(slot) return 1, "m", c.loot[slot][2] end

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

-- Text form ------------------------------------------------------------------

local Record = A.ns.Record
local text = Record.Serialize(own)
local back = Record.Parse(text)
check("text form survives a round trip", back and Record.Serialize(back) == text, text)
for name, bad in pairs({
    ["no header"] = "c,7421,333,125,126,0,0,0,0,0,0",
    ["code"] = "h,1,1;c,7421,333,125,126,0,0,0,0,0,os.exit()",
    ["lo above hi"] = "h,1,1;c,7421,333,126,125,0,0,0,0,0,0",
    ["more ups than crafts allow"] = "h,1,1;s,7418,125,1,1,9",
    ["material without item"] = "h,1,1;m,2584,10940,2,1",
    ["duplicate recipe"] = "h,1,1;c,7421,333,125,126,0,0,0,0,0,0;c,7421,333,125,126,0,0,0,0,0,0",
    ["unknown kind"] = "h,1,1;x,1",
    ["empty"] = "",
}) do
    check("rejects " .. name, Record.Parse(bad) == nil)
end

-- Guild sync -----------------------------------------------------------------

local B = newClient("B")
B.load(nil)
run(400)
local copy = B.db.peers[A.db.id]
check("B received A's record", copy and copy.rev == own.rev and Record.Serialize(copy) == text)
check("A holds nothing of B's empty record", next(A.db.peers) == nil)
local sentBefore = A.sent + B.sent
run(1800)
check("an idle guild only repeats hellos", A.sent + B.sent - sentBefore <= 6, A.sent + B.sent - sentBefore)

-- A logs out; C logs in and gets A's record from B.
A.online = false
local C = newClient("C")
C.load(nil)
run(2400)
local relayed = C.db.peers[A.db.id]
check("C received A's record from B", relayed and relayed.rev == own.rev and Record.Serialize(relayed) == text)

-- A comes back with one more observation; B and C follow.
A.online = true
A.load(A.db)   -- a login: the timers of the last session are gone
own = A.db.own
A.window = 333
A.profs[1].rank = 127
A.fire("TRADE_SKILL_LIST_UPDATE")
run(2400)
check("a change reaches both peers", B.db.peers[A.db.id].rev == own.rev and C.db.peers[A.db.id].rev == own.rev
    and B.db.peers[A.db.id].c[7421][3] == 127)

-- Sync switched off: nothing leaves.
B.ns.Command("sync off")
local sentB = B.sent
run(4000)
check("sync off sends nothing", B.sent == sentB)

-- A reload keeps token, id and data.
local token, id = A.db.token, A.db.id
A.load(A.db)
check("a reload keeps the token and the record", A.db.token == token and A.db.id == id and A.db.own.c[7421][3] == 127)
A.ns.Command("token")
check("/ledger token shows the popup", A.popup == "ROOKIELEDGER_TOKEN")

-- Two versions of one record passing at the same time (two holders asked at once): the newer one still arrives whole.
local newer, older = "h,1,1;c,7421,333,125,126,0,0,0,0,0,0", "h,1,1;c,7421,333,125,125,0,0,0,0,0,0"
for _, message in ipairs({
    "D,deadbeef,5,1,2," .. older:sub(1, 20), "D,deadbeef,7,1,2," .. newer:sub(1, 20),
    "D,deadbeef,5,2,2," .. older:sub(21), "D,deadbeef,7,2,2," .. newer:sub(21),
}) do
    C.fire("CHAT_MSG_ADDON", "RookieLedger", message, "GUILD", "X")
end
check("the newer of two crossing transfers is kept", C.db.peers.deadbeef and C.db.peers.deadbeef.rev == 7
    and C.db.peers.deadbeef.c[7421][3] == 126)

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
    -- B's file: its own (empty) record and A's as a peer; A's file: its own record.
    for suffix, client in pairs({ [""] = A, [".peer"] = B }) do
        local out = { "\nRookieLedgerDB = " }
        dump(client.db, out, 0)
        out[#out + 1] = "\n"
        local f = assert(io.open(OUT .. suffix, "w"))
        f:write(table.concat(out))
        f:close()
    end
    print("wrote " .. OUT)
end
for _, c in ipairs(clients) do
    for _, line in ipairs(c.printed) do
        assert(not line:find(c.db.token, 1, true) or line:find("jeton"), "token printed outside /ledger token")
    end
end
print("all checks passed")
