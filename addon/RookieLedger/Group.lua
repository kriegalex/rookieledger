-- Group.lua: while the player is in a group, writes down what the client tells of loot there, one line per thing
-- seen. It is a log for study, not part of the record: nothing in a group is counted (see Scan.lua), and what a
-- group's loot could be counted as is to be decided from these lines (docs/client-behaviour.md, section 11).
--
-- RookieLedgerGroup (one per WoW account, in the same saved file as RookieLedgerDB, so the companion app uploads it
-- with the record and the site keeps it apart) holds:
--   v   the format of the log, FORMAT.
--   k   time() when the log was begun: with n, it names a line for good.
--   n   how many lines were ever written.
--   l   the last MAX_LINES of them, oldest first: l[i] is line n - #l + i.
-- A line is "<time> <letter> <fields>", the time being seconds since 1970 with hundredths that are exact between
-- the lines of one session. The letters:
--   S   a session's first line: the client's build, the addon's version, the locale.
--   G   the group as it is now: members, loot method and threshold, kind of instance, map. Written when it changes.
--   D   a monster's death, written once the last of CHECKS has passed: how long ago it died, who the client named
--       as its killer, and what CanLootUnit answered at each of CHECKS.
--   W   a loot window: the loot method and threshold, then every slot with what it holds and the corpses it names.
--   E   one second after that window closed: what the character's coin grew by, and CanLootUnit for its corpses.
--   R   an event about a roll or a slot, with what it carries; for a roll that starts, also its item and the
--       monsters that died in the RECENT seconds before.
--   L   a chat line about an item: whose it is, the item, which of the client's texts it is, the numbers in it.
--   M   a chat line about coin: the amount, which of the client's texts it is.
-- No name is written, of a character or of anything else: a member is "me", "party2" or "other", an item its
-- number, a text of the client the name of its format. A corpse is the creature's number and a fingerprint of the
-- game's name for it ("c3100.9f3a61c2"): the same for every member who saw that corpse, which is how two members'
-- lines are put side by side, without the realm and the time of appearance that the name itself tells.
-- Like the rest of the addon, it sends nothing: these lines leave the computer in the saved file only.
local _, ns = ...

local Group = {}
ns.Group = Group

local FORMAT = 1
local MAX_LINES = 4000
local DROP = 500           -- lines let go at once when the log is full
local MAX_LINE = 1000      -- characters; a longer line is cut
local CHECKS = { 0.5, 2 }  -- seconds after a death at which the corpse is asked about
local RECENT = 5           -- seconds before a roll within which a death may be its cause
local MAX_ASKED = 500      -- deaths remembered, so that one announced twice is written once
local MONEY_SLOT = (Enum and Enum.LootSlotType and Enum.LootSlotType.Money) or LOOT_SLOT_MONEY or 2

local issecret = issecretvalue or function() return false end
local Party = C_PartyInfo or {}
local store      -- RookieLedgerGroup
local offset     -- time() less GetTime() at login
local begun      -- this session has written its S line

-- Writing ----------------------------------------------------------------------

local function Add(text)
    local lines = store.l
    lines[#lines + 1] = ("%.2f %s"):format(offset + GetTime(), text):sub(1, MAX_LINE)
    store.n = store.n + 1
    if #lines > MAX_LINES then
        local kept = {}
        for i = DROP + 1, #lines do
            kept[#kept + 1] = lines[i]
        end
        store.l = kept
    end
end

local function Write(text)
    if not begun then
        begun = true
        local locale = ns.Plain(ns.Try(GetLocale))
        Add(("S build=%d version=%s locale=%s"):format(ns.build or 0, tostring(ns.version):gsub("[^%w%.%-]", ""),
            type(locale) == "string" and locale:gsub("%W", "") or "?"))
    end
    Add(text)
end

local function InGroup()
    return ns.Try(IsInGroup) == true
end

-- What may be written of a value ---------------------------------------------------

-- Who a player's GUID names, as far as a line tells it.
local function Who(guid)
    if guid == ns.Plain(ns.Try(UnitGUID, "player")) then
        return "me"
    end
    local raid = ns.Try(IsInRaid) == true
    for i = 1, raid and 40 or 4 do
        local unit = (raid and "raid" or "party") .. i
        if guid == ns.Plain(ns.Try(UnitGUID, unit)) then
            return unit
        end
    end
    return "other"
end

local function Fingerprint(text)
    local h = 5381
    for i = 1, #text do
        h = (h * 33 + text:byte(i)) % 4294967296
    end
    return ("%04x%04x"):format(math.floor(h / 65536), h % 65536)
end

local KINDS = { Creature = "c", Vehicle = "c", GameObject = "o" }

-- A GUID as a line holds it: "c3100.9f3a61c2" for a creature, "o1731.…" for a world object, who it is for a
-- player. Nothing for any other text.
local function Thing(guid)
    local kind, id = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
    if KINDS[kind] then
        return KINDS[kind] .. id .. "." .. Fingerprint(guid)
    end
    if guid:match("^Player%-%d+%-%x+$") then
        return Who(guid)
    end
    return nil
end

-- A value as a line holds it. Of a text only what cannot be a name is kept: an item's number, a GUID as Thing
-- gives it, or a word of the client's own ("group", "party"; a character's name starts with a capital).
local function Safe(value)
    if issecret(value) then
        return "?"
    end
    local kind = type(value)
    if kind == "nil" then
        return "-"
    elseif kind == "boolean" then
        return value and "1" or "0"
    elseif kind == "number" then
        return tostring(value)
    elseif kind == "string" then
        local item = value:match("item:(%d+)")
        if item then
            return "i" .. item
        end
        return Thing(value) or (value:match("^%l+$") and #value <= 20 and value) or "s"
    end
    return "t"
end

local function List(...)
    local n = select("#", ...)
    if n == 0 then
        return "none"
    end
    local out = {}
    for i = 1, n do
        out[i] = Safe((select(i, ...)))
    end
    return table.concat(out, ",")
end

local function Pack(...)
    return { n = select("#", ...), ... }
end

-- The group --------------------------------------------------------------------

local function Method()
    local method = ns.Try(Party.GetLootMethod)
    if method == nil then
        method = ns.Try(GetLootMethod)
    end
    return Safe(method)
end

local function Threshold()
    return Safe((ns.Try(GetLootThreshold)))
end

local lastState

local function State()
    if not InGroup() then
        if lastState then
            lastState = nil
            Write("G none")
        end
        return
    end
    local _, instance = ns.Try(IsInInstance)
    local map = ns.Try((C_Map or {}).GetBestMapForUnit, "player")
    local text = ("G members=%s raid=%s method=%s threshold=%s instance=%s map=%s"):format(
        Safe((ns.Try(GetNumGroupMembers))), Safe((ns.Try(IsInRaid))), Method(), Threshold(), Safe(instance), Safe(map))
    if text ~= lastState then
        lastState = text
        Write(text)
    end
end

-- Deaths -----------------------------------------------------------------------

local asked, askedCount = {}, 0   -- [guid] = the death being asked about
local deaths = {}                 -- the last of them, for the rolls

-- A monster died. killer: the GUID the client named as its killer, when the event is the one that names one
-- (kill).
local function Died(guid, killer, kill)
    if not InGroup() then
        return
    end
    if issecret(guid) then
        if not kill then
            Write("D ?")   -- where the client hides which monster died: once per death, at the event all deaths have
        end
        return
    end
    local thing = type(guid) == "string" and Thing(guid)
    if not thing or thing:sub(1, 1) ~= "c" then
        return
    end
    if issecret(killer) then
        killer = "?"
    else
        killer = type(killer) == "string" and Who(killer) or nil
    end
    local death = asked[guid]
    if death then
        death.by = killer or death.by   -- the same death, told by the other event
        return
    end
    if askedCount >= MAX_ASKED then
        asked, askedCount = {}, 0
    end
    death = { at = GetTime(), thing = thing, by = killer, can = {} }
    asked[guid], askedCount = death, askedCount + 1
    deaths[#deaths + 1] = death
    if #deaths > 20 then
        table.remove(deaths, 1)
    end
    for i, delay in ipairs(CHECKS) do
        C_Timer.After(delay, function()
            death.can[#death.can + 1] = ("%.1f=%s"):format(delay, List(ns.Try(CanLootUnit, guid)))
            if i == #CHECKS then
                Write(("D %s %.2f by=%s %s"):format(thing, death.at - GetTime(), death.by or "-", table.concat(death.can, " ")))
            end
        end)
    end
end

-- Loot windows -----------------------------------------------------------------

local window                       -- the open one, once written: { money, corpses = { { guid, thing } } }
local lastSlots, lastSlotsAt = nil, 0

local function Window()
    if not InGroup() then
        return
    end
    local n = ns.Plain(ns.Try(GetNumLootItems))
    if type(n) ~= "number" or n < 1 then
        return   -- announced before its content is there
    end
    local slots, corpses, known = {}, {}, {}
    for slot = 1, n do
        local _, name, quantity, _, quality, locked, quest = ns.Try(GetLootSlotInfo, slot)
        local link = ns.Plain(ns.Try(GetLootSlotLink, slot))
        local item = type(link) == "string" and link:match("item:(%d+)")
        local text
        if item then
            text = "i" .. item .. "x" .. Safe(quantity) .. "q" .. Safe(quality)
                .. (ns.Plain(locked) == true and "L" or "") .. (ns.Plain(quest) == true and "Q" or "")
        elseif ns.Plain(ns.Try(GetLootSlotType, slot)) == MONEY_SLOT then
            text = "coin=" .. (ns.Scan.Copper(ns.Plain(name)) or "?")
        else
            text = "slot=" .. Safe((ns.Try(GetLootSlotType, slot)))
        end
        local sources, from = Pack(ns.Try(GetLootSourceInfo, slot)), {}
        for j = 1, sources.n - 1, 2 do
            local guid = ns.Plain(sources[j])
            local thing = Safe(sources[j])
            from[#from + 1] = thing .. "*" .. Safe(sources[j + 1])
            if type(guid) == "string" and thing:sub(1, 1) == "c" and not known[guid] then
                known[guid] = true
                corpses[#corpses + 1] = { guid, thing }
            end
        end
        slots[#slots + 1] = text .. "@" .. (#from > 0 and table.concat(from, "/") or "-")
    end
    local text = table.concat(slots, " ")
    if text == lastSlots and GetTime() - lastSlotsAt < 1.5 then
        return   -- the game announces one window twice
    end
    lastSlots, lastSlotsAt = text, GetTime()
    window = { money = ns.Plain(ns.Try(GetMoney)), corpses = corpses }
    Write(("W method=%s threshold=%s %s"):format(Method(), Threshold(), text))
end

local function Closed()
    local closed = window
    window = nil
    if not closed then
        return
    end
    C_Timer.After(1, function()
        local money = ns.Plain(ns.Try(GetMoney))
        local known = type(money) == "number" and type(closed.money) == "number"
        local parts = { "E purse=" .. (known and ("%+d"):format(money - closed.money) or "?") }
        for _, corpse in ipairs(closed.corpses) do
            parts[#parts + 1] = corpse[2] .. "=" .. List(ns.Try(CanLootUnit, corpse[1]))
        end
        Write(table.concat(parts, " "))
    end)
end

-- Chat lines ---------------------------------------------------------------------
-- The text of a chat line holds names. Of it are written: the item it links, which of the client's own formats it
-- follows (told by that format's name, as LOOT_ITEM_SELF), and the numbers the format has a place for.

local LOOT_TEXTS = {
    "LOOT_ITEM_SELF_MULTIPLE", "LOOT_ITEM_SELF", "LOOT_ITEM_PUSHED_SELF_MULTIPLE", "LOOT_ITEM_PUSHED_SELF",
    "LOOT_ITEM_MULTIPLE", "LOOT_ITEM", "LOOT_ROLL_YOU_WON", "LOOT_ROLL_WON", "LOOT_ROLL_ROLLED_NEED",
    "LOOT_ROLL_ROLLED_GREED", "LOOT_ROLL_ROLLED_DE", "LOOT_ROLL_NEED_SELF", "LOOT_ROLL_GREED_SELF",
    "LOOT_ROLL_PASSED_SELF", "LOOT_ROLL_NEED", "LOOT_ROLL_GREED", "LOOT_ROLL_PASSED", "LOOT_ROLL_ALL_PASSED",
}
local MONEY_TEXTS = { "LOOT_MONEY_SPLIT", "YOU_LOOT_MONEY", "LOOT_MONEY" }
local patterns = {}   -- [format's name] = the pattern that reads a text made with it, false without that format

-- The first of names whose format the text follows, and the numbers it holds there ("-" for none).
local function Format(text, names)
    for _, name in ipairs(names) do
        local pattern = patterns[name]
        if pattern == nil then
            local format = _G[name]
            pattern = type(format) == "string" and ("^" .. format:gsub("%%%d%$", "%%")
                :gsub("([%^%$%(%)%.%[%]%*%+%-%?])", "%%%1"):gsub("%%s", ".-"):gsub("%%d", "(%%d+)") .. "$") or false
            patterns[name] = pattern
        end
        local found = pattern and { text:find(pattern) }
        if found and found[1] then
            return name, #found > 2 and table.concat(found, ",", 3) or "-"
        end
    end
    return "-", "-"
end

local function ChatLoot(text, _, _, _, _, _, _, _, _, _, _, guid)
    if not InGroup() then
        return
    end
    text, guid = ns.Plain(text), ns.Plain(guid)
    if type(text) ~= "string" then
        Write("L ? ? - -")
        return
    end
    local item = text:match("item:(%d+)")
    Write(("L %s %s %s %s"):format(type(guid) == "string" and Thing(guid) or "?", item and ("i" .. item) or "?",
        Format(text, LOOT_TEXTS)))
end

local function ChatMoney(text)
    if not InGroup() then
        return
    end
    text = ns.Plain(text)
    if type(text) ~= "string" then
        Write("M ? -")
        return
    end
    Write(("M %s %s"):format(ns.Scan.Copper(text) or "?", (Format(text, MONEY_TEXTS))))
end

-- Rolls ------------------------------------------------------------------------

local function Roll(event, ...)
    if not InGroup() then
        return
    end
    local line = "R " .. event .. " " .. List(...)
    if event == "START_LOOT_ROLL" then
        local roll = ns.Plain((...))
        local recent = {}
        for _, death in ipairs(deaths) do
            if GetTime() - death.at <= RECENT then
                recent[#recent + 1] = ("%s:%.2f"):format(death.thing, death.at - GetTime())
            end
        end
        line = line .. (" item=%s info=%s deaths=%s"):format(Safe((ns.Try(GetLootRollItemLink, roll))),
            List(ns.Try(GetLootRollItemInfo, roll)), #recent > 0 and table.concat(recent, "/") or "none")
    end
    Write(line)
end

-- Events -----------------------------------------------------------------------

local handlers = {
    GROUP_ROSTER_UPDATE = State,
    PARTY_LOOT_METHOD_CHANGED = State,
    PLAYER_ENTERING_WORLD = State,
    ZONE_CHANGED_NEW_AREA = State,
    PARTY_KILL = function(killer, guid) Died(guid, killer, true) end,
    UNIT_DIED = function(guid) Died(guid) end,
    LOOT_READY = Window,
    LOOT_CLOSED = Closed,
    CHAT_MSG_LOOT = ChatLoot,
    CHAT_MSG_MONEY = ChatMoney,
}
for _, event in ipairs({ "START_LOOT_ROLL", "CANCEL_LOOT_ROLL", "LOOT_ROLLS_COMPLETE", "LOOT_ITEM_ROLL_WON",
    "LOOT_ITEM_AVAILABLE", "LOOT_HISTORY_UPDATE_DROP", "LOOT_SLOT_CLEARED" }) do
    handlers[event] = function(...) Roll(event, ...) end
end

function Group.Init()
    store = RookieLedgerGroup
    if type(store) ~= "table" or store.v ~= FORMAT or type(store.l) ~= "table" or type(store.n) ~= "number"
        or type(store.k) ~= "number" or #store.l > store.n then
        store = { v = FORMAT, k = time(), n = 0, l = {} }
        RookieLedgerGroup = store
    end
    offset = time() - GetTime()
    local frame = CreateFrame("Frame")
    for event in pairs(handlers) do
        pcall(frame.RegisterEvent, frame, event)   -- a client without one of them refuses it, and loses only that
    end
    frame:SetScript("OnEvent", function(_, event, ...)
        pcall(handlers[event], ...)   -- a line that cannot be written costs that line
    end)
    State()
end
