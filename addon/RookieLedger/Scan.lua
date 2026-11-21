-- Scan.lua: reads what the game shows and notes it in our record.
--
-- Recipe colours: while one of our own profession windows is open, the colour of every learned recipe at the
--   current skill (C_TradeSkillUI.GetRecipeInfo().relativeDifficulty: 0 orange, 1 yellow, 2 green, 3 grey).
-- Skill-ups: for each craft of a recipe we have seen in a window, the skill and colour before it and the points gained.
-- Disenchants: the item that left the bags during a Disenchant cast, and what the loot window it opened held.
-- Gathering: after a Mining or Herb Gathering cast, the vein or herb the loot window names as its source, what it
--   held, and where on the map the player stood.
-- Monster loot: for every corpse a loot window names as a source, the kind of monster, the items of every quality
--   and the coin it held. Only while not in a group (there a corpse is one member's to open, and its window leaves
--   out what the group rolls for: Group.lua writes down what is seen there), only what is not a quest item, and
--   each corpse once. A window opened by Skinning or Pick Pocket names a creature too, but holds
--   nothing it dropped: it is not read.
-- Quest items: a quest item only drops for who has the quest, so it is counted apart, against the corpses looted
--   while the quest still wanted it. Which quest that is comes from the quest log: the objective whose text names
--   the item (see "Quest items" further down).
--
-- Nothing is recorded for a profession while its skill carries a bonus (racial, enchant, lure): colours and
-- skill-ups follow the boosted skill, and mixing the two would blur the thresholds.
local _, ns = ...

local Scan = {}
ns.Scan = Scan

local Record = ns.Record
local TradeSkill = C_TradeSkillUI or {}
local Difficulty = Enum and Enum.TradeskillRelativeDifficulty or {}
local COLOUR = {
    [Difficulty.Optimal or 0] = 0,
    [Difficulty.Medium or 1] = 1,
    [Difficulty.Easy or 2] = 2,
    [Difficulty.Trivial or 3] = 3,
}
local DISENCHANT = 13262
local SCAN_DELAY = 1        -- after the window's last change
local SETTLE = 1.5          -- after a skill point: the window's colours follow the new skill a moment later
local UPS_DELAY = 1.2       -- after a craft, before reading the points it gave
local DISENCHANT_TIMEOUT = 10
local EARLY_LOOT = 0.5      -- a loot window this shortly before the cast's end is taken for its result
local GATHER = { [2575] = 1, [2366] = 2 }   -- Mining, Herb Gathering: the kind of node (see Record.lua)
local GATHER_TIMEOUT = 10   -- from the start of the cast to its loot window
local NOT_A_DROP = { [8613] = "skin", [921] = "pocket" }   -- Skinning, Pick Pocket: loot of a creature that it did not drop

local SpellName = (C_Spell and C_Spell.GetSpellName) or GetSpellInfo

-- What the log says ------------------------------------------------------------
-- The window's log shows names, which the record does not hold: they are taken here, when the thing is recorded.

local links = {}   -- [item id] = the last link a loot window or the bags gave for it

local function ItemText(item)
    return links[item] or ns.L.item:format(item)
end

-- "link x2, link" for { [item] = quantity }, in the order of the ids.
local function LootText(loot)
    local ids = {}
    for item in pairs(loot) do
        ids[#ids + 1] = item
    end
    table.sort(ids)
    for i, item in ipairs(ids) do
        ids[i] = ItemText(item) .. (loot[item] > 1 and (" x" .. loot[item]) or "")
    end
    return #ids > 0 and table.concat(ids, ", ") or nil
end

local function CoinText(copper)
    return ns.Plain(ns.Try(GetCoinTextureString, copper)) or ns.L.copper:format(copper)
end

-- The name of the creature a GUID names, if the player points at it; else "creature 118".
local function CreatureText(guid, creature)
    for _, unit in ipairs({ "target", "mouseover", "softinteract" }) do
        if ns.Plain(ns.Try(UnitGUID, unit)) == guid then
            local name = ns.Plain(ns.Try(UnitName, unit))
            if type(name) == "string" and name ~= "" then
                return name
            end
        end
    end
    return ns.L.creature:format(creature)
end

local timers = {}

-- Runs f once, delay seconds after the last call with this key.
local function Debounce(key, delay, f)
    timers[key] = (timers[key] or 0) + 1
    local mine = timers[key]
    C_Timer.After(delay, function()
        if timers[key] == mine then
            f()
        end
    end)
end

-- Professions ----------------------------------------------------------------

-- [skill line] = { rank, bonus } for the character's professions.
local function Ranks()
    local found = {}
    local indices = { GetProfessions() }
    for i = 1, select("#", GetProfessions()) do
        local index = indices[i]
        if index then
            local _, _, rank, _, _, _, skillLine, bonus = GetProfessionInfo(index)
            rank, skillLine, bonus = ns.Plain(rank), ns.Plain(skillLine), ns.Plain(bonus)
            if type(skillLine) == "number" and skillLine > 0 and type(rank) == "number" then
                found[skillLine] = { rank, type(bonus) == "number" and bonus or 0 }
            end
        end
    end
    return found
end

-- True while the open profession window shows our own profession.
local function IsOwnSession()
    if ns.Try(TradeSkill.IsTradeSkillReady) ~= true or ns.Try(TradeSkill.IsDataSourceChanging) == true then
        return false
    end
    for _, check in ipairs({ TradeSkill.IsTradeSkillLinked, TradeSkill.IsTradeSkillGuild, TradeSkill.IsTradeSkillGuildMember, TradeSkill.IsNPCCrafting }) do
        if ns.Try(check) then
            return false
        end
    end
    return true
end

local function SessionSkillLine()
    local info = ns.Try(TradeSkill.GetChildProfessionInfo)
    if type(info) ~= "table" or not info.professionID or info.professionID == 0 then
        info = ns.Try(TradeSkill.GetBaseProfessionInfo)
    end
    if type(info) ~= "table" then
        return nil
    end
    local parent = ns.Plain(info.parentProfessionID)
    if type(parent) == "number" and parent > 0 then
        return parent
    end
    return ns.Plain(info.professionID)
end

local function RecipeColour(recipe)
    local info = ns.Try(TradeSkill.GetRecipeInfo, recipe)
    if type(info) ~= "table" then
        return nil
    end
    return COLOUR[ns.Plain(info.relativeDifficulty)], info
end

-- Recipe colours -------------------------------------------------------------

local lastRank = {}     -- [skill line] = the rank of the last scan
local warned = {}

function Scan.Colours()
    if not IsOwnSession() then
        return
    end
    local skillLine = SessionSkillLine()
    local rank = skillLine and Ranks()[skillLine]
    if not rank or rank[1] <= 0 then
        return
    end
    if rank[2] ~= 0 then
        if not warned[skillLine] then
            warned[skillLine] = true
            ns.Print(ns.L.skipped)
        end
        return
    end
    if lastRank[skillLine] and lastRank[skillLine] ~= rank[1] then
        -- The skill just moved: the window may still show the colours of the old one.
        lastRank[skillLine] = rank[1]
        Debounce("colours", SETTLE, Scan.Colours)
        return
    end
    lastRank[skillLine] = rank[1]

    local ids = ns.Try(TradeSkill.GetAllRecipeIDs)
    if type(ids) ~= "table" or #ids == 0 then
        ids = ns.Try(TradeSkill.GetFilteredRecipeIDs)
    end
    local changed = 0
    for _, recipe in ipairs(type(ids) == "table" and ids or {}) do
        local colour, info = RecipeColour(recipe)
        if colour and info.learned and not info.isDummyRecipe and type(recipe) == "number" then
            if Record.Observe(ns.db.own, recipe, skillLine, colour, rank[1]) then
                changed = changed + 1
            end
        end
    end
    if changed > 0 then
        ns.Touch()
        ns.Log("c", ns.L.logColours:format(changed), changed)
    end
end

-- Skill-ups ------------------------------------------------------------------

local craft      -- the craft under way: { recipe, skillLine, rank, colour, cast, after, late }
local settling   -- the craft done last, until the points it gave are read

-- Reads the points of the craft that is done. The client gives them a moment after the craft, and in a queue after
-- the next craft has started (docs/client-behaviour.md, section 10): so the skill read when that next craft started
-- is still the skill before these points, and is read again here, where they are in.
local function ResolveCraft()
    local c = settling
    if not c then
        return
    end
    settling = nil
    local rank = Ranks()[c.skillLine]
    local now = rank and rank[2] == 0 and rank[1] or nil
    if craft and craft.after == c then
        if now then
            craft.after, craft.rank, craft.late = nil, now, true
        else
            craft = nil   -- the skill it is made at cannot be told
        end
    end
    if not now then
        return
    end
    local ups = now - c.rank
    if ups < 0 or ups > 5 then
        return
    end
    Record.Craft(ns.db.own, c.recipe, c.rank, c.colour, ups)
    ns.Touch()
    local name = ns.Plain((ns.Try(SpellName, c.recipe)))
    name = type(name) == "string" and name or ns.L.recipe:format(c.recipe)
    ns.Log("s", ups > 0 and ns.L.logUp:format(name, ups) or ns.L.logNoUp:format(name))
end

local function CraftStarted(recipe)
    local entry = ns.db.own.c[recipe]
    if not entry then
        return nil
    end
    local rank = Ranks()[entry[1]]
    local colour = RecipeColour(recipe)
    if not rank or rank[2] ~= 0 or rank[1] <= 0 or not colour then
        return nil
    end
    craft = { recipe = recipe, skillLine = entry[1], rank = rank[1], colour = colour }
    if settling and settling.skillLine == craft.skillLine then
        craft.after = settling   -- the craft before it in a queue: its points may still move this one's skill
    end
    return craft
end

local function CraftSucceeded(recipe)
    if not craft or craft.recipe ~= recipe then
        -- No cast bar came first (an instant craft): take the state as it is now.
        if not CraftStarted(recipe) then
            return
        end
    end
    ResolveCraft()   -- the craft before, if a cast shorter than UPS_DELAY left it unread: its points are in by now
    local mine = craft
    if not mine then
        return
    end
    if mine.late then
        -- It started before the window showed the colours of its skill: by now the window has followed.
        mine.colour = RecipeColour(recipe) or mine.colour
    end
    craft, settling = nil, mine
    C_Timer.After(UPS_DELAY, function()
        if settling == mine then
            ResolveCraft()
        end
    end)
end

-- True when a failure event names another cast than the one we follow: the game also reports as failed, under the
-- same spell, an attempt it refused because that cast was still under way.
local function OtherCast(mine, cast)
    return mine ~= nil and cast ~= nil and mine ~= cast
end

local function CraftFailed(recipe, cast)
    if craft and craft.recipe == recipe and not OtherCast(craft.cast, cast) then
        craft = nil
    end
end

-- Disenchants ----------------------------------------------------------------

local Container = C_Container or {}
local ItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local function ItemID(link)
    return type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
end

-- The kind of thing a GUID names and the game's id of it: "Creature", 118 for
-- "Creature-0-<server>-<instance>-<zone>-118-<spawn>". Nothing for a GUID of another shape.
local function GuidKind(guid)
    if type(guid) ~= "string" then
        return nil
    end
    local kind, id = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
    return kind, tonumber(id)
end

-- The game's id of the creature a GUID names, or nil. Some monsters are named as vehicles.
local function CreatureID(guid)
    local kind, id = GuidKind(guid)
    return (kind == "Creature" or kind == "Vehicle") and id or nil
end

-- What a call returned, with n their number: a nil among them does not end the list.
local function Pack(...)
    return { n = select("#", ...), ... }
end

-- [item id] = { count, link } for the green and better items in the bags.
local function Bags()
    local found = {}
    for bag = 0, NUM_BAG_SLOTS or 4 do
        for slot = 1, ns.Try(Container.GetContainerNumSlots, bag) or 0 do
            local info = ns.Try(Container.GetContainerItemInfo, bag, slot)
            if type(info) == "table" and (ns.Plain(info.quality) or 0) >= 2 then
                local link = ns.Plain(info.hyperlink)
                local id = ItemID(link)
                if id then
                    links[id] = link
                    local entry = found[id] or { 0, link }
                    entry[1] = entry[1] + (ns.Plain(info.stackCount) or 1)
                    found[id] = entry
                end
            end
        end
    end
    return found
end

local destroy   -- the disenchant under way: { bags, t, cast, done, loot, early, earlyAt }

-- The disenchant under way, or nil. One that started longer ago than DISENCHANT_TIMEOUT is forgotten first: when its
-- result never showed in a loot window, the next loot window (a corpse, a chest) is not its result either.
local function PendingDisenchant()
    if destroy and GetTime() - destroy.t > DISENCHANT_TIMEOUT then
        destroy = nil
    end
    return destroy
end

local function ReadLoot()
    local loot, any = {}, false
    for slot = 1, ns.Try(GetNumLootItems) or 0 do
        local link = ns.Plain(ns.Try(GetLootSlotLink, slot))
        local id = ItemID(link)
        local _, _, quantity = ns.Try(GetLootSlotInfo, slot)
        quantity = ns.Plain(quantity)
        if id then
            links[id] = link
        end
        if id and type(quantity) == "number" and quantity > 0 then
            loot[id] = (loot[id] or 0) + quantity
            any = true
        end
    end
    return any and loot or nil
end

-- Whether the open loot window comes from an item (a disenchant), as far as the client tells: true, false for a
-- corpse or a chest, nil when it names no source.
local function LootFromItem()
    if type(GetLootSourceInfo) ~= "function" then
        return nil
    end
    local verdict
    for slot = 1, ns.Try(GetNumLootItems) or 0 do
        local source = ns.Plain((ns.Try(GetLootSourceInfo, slot)))
        if type(source) == "string" then
            if source:sub(1, 5) ~= "Item-" then
                return false
            end
            verdict = true
        end
    end
    return verdict
end

-- A loot window opened while a disenchant is under way. It is the disenchant's result when the client says it comes
-- from an item, or names no source and the cast has ended; a corpse looted during the cast is not.
local function LootOpened(pending)
    local fromItem = LootFromItem()
    if fromItem == false then
        return
    end
    if fromItem or pending.done then
        pending.loot = ReadLoot()
    else
        pending.early, pending.earlyAt = ReadLoot(), GetTime()   -- counts if the cast ends within EARLY_LOOT
    end
end

local function ResolveDisenchant()
    local d = destroy
    if not d or not d.done or not d.loot then
        return
    end
    -- The disenchanted item is the one green or better item the bags hold one less of.
    local now = Bags()
    local gone, link
    for id, entry in pairs(d.bags) do
        local left = now[id] and now[id][1] or 0
        if left < entry[1] then
            if gone or entry[1] - left ~= 1 then
                destroy = nil   -- something else moved during the cast: no telling which item it was
                return
            end
            gone, link = id, entry[2]
        end
    end
    if not gone then
        return   -- the bags have not caught up yet: the next bag update comes back here
    end
    destroy = nil
    local _, _, quality, level, _, _, _, _, _, _, _, class = ItemInfo(link)
    quality, level, class = ns.Plain(quality), ns.Plain(level), ns.Plain(class)
    if type(quality) ~= "number" or type(level) ~= "number" or (class ~= 2 and class ~= 4)
        or quality < 2 or quality > 4 or level < 1 then
        return
    end
    Record.Disenchant(ns.db.own, gone, level, quality, class, d.loot)
    ns.Touch()
    ns.Log("d", ns.L.logDisenchant:format(ItemText(gone), LootText(d.loot) or ns.L.nothing))
end

-- Gathering ------------------------------------------------------------------

local NAME_TRIES = 5   -- casts after which a name the client still does not give is done without
-- [GATHER or NOT_A_DROP] = { names = { [spell name] = value }, tries = casts that asked for the names,
--   spells = { [spell id] = value, false for a spell that is not one of them } }
-- The higher ranks are other spells under the same name. Every cast of the player comes through here: a spell is
-- asked about by name once, then answered from spells.
local ranks = {}

-- What known holds for spell or for another rank of it, nil for any other spell.
local function ByName(known, spell)
    if known[spell] then
        return known[spell]
    end
    local rank = ranks[known]
    if not rank then
        rank = { tries = 0 }
        ranks[known] = rank
    end
    local value = rank.spells and rank.spells[spell]
    if value ~= nil then
        return value or nil
    end
    local names = rank.names
    if not names then
        names = {}
        local all = true
        for id, kind in pairs(known) do
            local name = ns.Plain((ns.Try(SpellName, id)))
            if type(name) == "string" then
                names[name] = kind
            else
                all = false
            end
        end
        rank.tries = rank.tries + 1
        if all or rank.tries >= NAME_TRIES then
            -- Else asked again at the next cast: the client did not have every name yet.
            rank.names, rank.spells = names, {}
        end
    end
    local name = ns.Plain((ns.Try(SpellName, spell)))
    value = type(name) == "string" and names[name] or nil
    if rank.spells and type(name) == "string" then
        rank.spells[spell] = value or false
    end
    return value
end

-- 1 for a mining cast, 2 for a herb gathering one, nil for any other spell.
local function GatherKind(spell)
    return ByName(GATHER, spell)
end

local gather   -- the gathering cast under way: { kind, t, cast }

-- Where the player stands: map id and x, y in thousandths of that map, or nil (the client gives none in instances).
local function Place()
    local Map = C_Map or {}
    local map = ns.Plain((ns.Try(Map.GetBestMapForUnit, "player")))
    if type(map) ~= "number" or map < 1 then
        return nil
    end
    local position = ns.Try(Map.GetPlayerMapPosition, map, "player")
    if type(position) ~= "table" or type(position.GetXY) ~= "function" then
        return nil
    end
    local x, y = ns.Try(position.GetXY, position)
    x, y = ns.Plain(x), ns.Plain(y)
    if type(x) ~= "number" or type(y) ~= "number" or x < 0 or x > 1 or y < 0 or y > 1 then
        return nil
    end
    return map, math.floor(x * 1000 + 0.5), math.floor(y * 1000 + 0.5)
end

-- The game's id of the vein or herb the open loot window comes from, or nil: the window must name a world object
-- (not a corpse, not an item) as the source of what it holds.
local function LootNode()
    if type(GetLootSourceInfo) ~= "function" then
        return nil
    end
    local node
    for slot = 1, ns.Try(GetNumLootItems) or 0 do
        local source = ns.Plain((ns.Try(GetLootSourceInfo, slot)))
        if type(source) == "string" then
            local kind, id = GuidKind(source)
            if kind ~= "GameObject" or not id or (node and node ~= id) then
                return nil
            end
            node = id
        end
    end
    return node
end

-- A loot window opened after a gathering cast. True when it was the vein's or herb's and has been recorded.
local function GatherLoot()
    local g = gather
    if not g or GetTime() - g.t > GATHER_TIMEOUT then
        gather = nil
        return
    end
    local node = LootNode()
    local loot = node and ReadLoot()
    if not loot then
        return
    end
    gather = nil
    Record.Gather(ns.db.own, node, g.kind, loot, Place())
    ns.Touch()
    ns.Log("g", (g.kind == 1 and ns.L.vein or ns.L.herb) .. ns.L.colon .. (LootText(loot) or ns.L.nothing))
    return true
end

-- Quest items -----------------------------------------------------------------

local QuestLog = C_QuestLog or {}
local questItems   -- [creature] = { [item] = its entry in the record }, the quest items known to drop from it

-- { { quest, objective, text } } for the objectives of the quest log that still want an item. The text reads
-- "Darkhound Blood: 1/5": it is all the client tells of which item that is.
local function WantedItems()
    local wanted = {}
    for index = 1, ns.Plain(ns.Try(QuestLog.GetNumQuestLogEntries)) or 0 do
        local info = ns.Try(QuestLog.GetInfo, index)
        local quest = type(info) == "table" and not ns.Plain(info.isHeader) and ns.Plain(info.questID)
        if type(quest) == "number" then
            local objectives = ns.Try(QuestLog.GetQuestObjectives, quest)
            for j, objective in ipairs(type(objectives) == "table" and objectives or {}) do
                if type(objective) == "table" and ns.Plain(objective.type) == "item" and ns.Plain(objective.finished) == false then
                    wanted[#wanted + 1] = { quest, j, ns.Plain(objective.text) }
                end
            end
        end
    end
    return wanted
end

-- The quest and objective that want the item of that name, when exactly one does. The name must be all that stands
-- before the colon: "Claw" is not what "Claw of the Bear: 0/3" asks for. Some languages put a space before the
-- colon, and not always a plain one.
local function WantedBy(wanted, name)
    local quest, objective
    for _, w in ipairs(wanted) do
        local text = w[3]
        if type(text) == "string" and text:sub(1, #name) == name and text:sub(#name + 1):find("^[^%w]*:") then
            if quest then
                return nil
            end
            quest, objective = w[1], w[2]
        end
    end
    return quest, objective
end

local function StillWanted(wanted, quest, objective)
    for _, w in ipairs(wanted) do
        if w[1] == quest and w[2] == objective then
            return true
        end
    end
    return false
end

-- A corpse of creature, counted for the first time. dropped: { [quest item] = quantity } it held, names: their
-- names. True when the record changed.
local function QuestChances(creature, dropped, names)
    local known = questItems[creature]
    if not known and not next(dropped) then
        return false
    end
    local wanted = WantedItems()
    local changed = false
    for item, entry in pairs(known or {}) do
        if StillWanted(wanted, entry.q, entry.j) then
            Record.QuestChance(entry, dropped[item])
            changed = true
        end
    end
    -- A quest item not seen from this creature before: the corpse tells that it drops, not how often, and is left
    -- out of the count that starts here.
    for item in pairs(dropped) do
        if not (known and known[item]) and type(names[item]) == "string" and names[item] ~= "" then
            local quest, objective = WantedBy(wanted, names[item])
            local entry = quest and Record.QuestItem(ns.db.own, creature, item, quest, objective)
            if entry then
                questItems[creature] = questItems[creature] or {}
                questItems[creature][item] = entry
                changed = true
            end
        end
    end
    return changed
end

-- Reads the quest items the record already knows, by creature.
local function LoadQuestItems()
    questItems = {}
    for key, entry in pairs(ns.db.own.q) do
        local creature, item
        if type(key) == "string" then
            creature, item = key:match("^(%d+):(%d+)$")
        end
        if creature and type(entry) == "table" and type(entry.q) == "number" and type(entry.j) == "number"
            and type(entry.n) == "number" and type(entry.k) == "number" and type(entry.t) == "number" then
            creature, item = tonumber(creature), tonumber(item)
            questItems[creature] = questItems[creature] or {}
            questItems[creature][item] = entry
        end
    end
end

-- Monster loot ---------------------------------------------------------------

local MONEY_SLOT = (Enum and Enum.LootSlotType and Enum.LootSlotType.Money) or LOOT_SLOT_MONEY or 2
local MAX_SEEN = 500
-- Corpses already counted: a corpse opened again shows what was left. seenOrder holds the last MAX_SEEN of them as
-- a ring, seenNext being the place of the oldest. The ring is this character's saved table (see Core.lua), so a
-- corpse counted before a reload or a new login is still known after it; a corpse does not outlast that many others.
local seen, seenOrder, seenNext = {}, {}, 1
local here   -- ns.here once the saved ring is taken up
-- The last Skinning or Pick Pocket cast: { t, cast, skin, taken }. t is when it was last heard of, skin whether it
-- is Skinning, taken whether its loot window has opened.
local taking

-- Notes a corpse as counted. False when it already was.
local function MarkSeen(guid)
    if seen[guid] then
        return false
    end
    local oldest = seenOrder[seenNext]
    if oldest then
        seen[oldest] = nil
    end
    seen[guid] = true
    seenOrder[seenNext] = guid
    seenNext = seenNext % MAX_SEEN + 1
    if here then
        here.next = seenNext
    end
    return true
end

-- Takes up the ring this character saved, oldest first, and saves the one in use from now on. Whatever the file
-- holds that is not a corpse's name is left out.
local function LoadSeen()
    local kept, from = ns.here.seen, ns.here.next
    seen, seenOrder, seenNext, here = {}, {}, 1, nil
    if type(kept) == "table" then
        local n = math.min(#kept, MAX_SEEN)
        if type(from) ~= "number" or from < 1 or from > n or from % 1 ~= 0 then
            from = 1   -- a ring that is not full yet starts at its first place
        end
        for i = 0, n - 1 do
            local guid = kept[(from + i - 1) % n + 1]
            if type(guid) == "string" then
                MarkSeen(guid)
            end
        end
    end
    here = ns.here
    here.seen, here.next = seenOrder, seenNext
end

-- The open window is Skinning's. The corpses it names show nothing they dropped from now on: opened again without
-- a cast, they hold the hide that was left in the window.
local function SkinLoot()
    for slot = 1, ns.Try(GetNumLootItems) or 0 do
        local sources = Pack(ns.Try(GetLootSourceInfo, slot))
        for j = 1, sources.n, 2 do
            local guid = ns.Plain(sources[j])
            if CreatureID(guid) then
                MarkSeen(guid)
            end
        end
    end
end

local coinPatterns = {}   -- [one of the client's formats, "%d Gold"] = the pattern that reads its number

-- Adds to total the coin that text names in format, worth copper apiece, and takes it out of rest.
local function Coin(text, rest, total, format, worth)
    if type(format) ~= "string" then
        return total, rest
    end
    local pattern = coinPatterns[format]
    if not pattern then
        pattern = format:gsub("([%^%$%(%)%.%[%]%*%+%-%?])", "%%%1"):gsub("%%d", "(%%d+)")
        coinPatterns[format] = pattern
    end
    local amount = tonumber((text:match(pattern)))
    if not amount then
        return total, rest
    end
    return (total or 0) + amount * worth, (rest:gsub(pattern, "", 1))
end

-- The coin a money slot's text names, in copper, read with the client's own "%d Gold" / "%d Silver" / "%d Copper".
local function Copper(text)
    if type(text) ~= "string" then
        return nil
    end
    local total, rest = nil, text
    total, rest = Coin(text, rest, total, GOLD_AMOUNT, 10000)
    total, rest = Coin(text, rest, total, SILVER_AMOUNT, 100)
    total, rest = Coin(text, rest, total, COPPER_AMOUNT, 1)
    -- Every number in the text must have been read: a part of the coin is not the coin. A digit the format itself
    -- holds (the plural mark of some locales, "%d |4coin:coins;") is not one of them.
    return total and not rest:find("%d") and total or nil
end
Scan.Copper = Copper

-- A loot window that is neither a disenchant's nor a gather's: corpses, if every source it names is one.
local function CorpseLoot()
    if ns.Try(IsInGroup) == true or type(GetLootSourceInfo) ~= "function" then
        return
    end
    local corpses, order = {}, {}   -- [guid] = { creature, items = {} }
    local windowCopper, shares = nil, nil
    for slot = 1, ns.Try(GetNumLootItems) or 0 do
        local sources = Pack(ns.Try(GetLootSourceInfo, slot))
        local named = math.ceil(sources.n / 2)   -- the corpses this slot names
        local _, name, quantity, _, _, _, quest = ns.Try(GetLootSlotInfo, slot)
        quantity = ns.Plain(quantity)
        if type(quantity) ~= "number" or quantity < 1 then
            quantity = 1   -- never 0: the site refuses a record that holds an item less often than it counts it
        end
        local link = ns.Plain(ns.Try(GetLootSlotLink, slot))
        local item = ItemID(link)
        if item then
            links[item] = link
        end
        local money = not item and ns.Plain(ns.Try(GetLootSlotType, slot)) == MONEY_SLOT
        if money then
            windowCopper, shares = Copper(ns.Plain(name)), {}
        end
        for j = 1, sources.n, 2 do
            local guid, amount = ns.Plain(sources[j]), ns.Plain(sources[j + 1])
            local creature = CreatureID(guid)
            if not creature then
                return   -- a chest, an item, or a source the client keeps to itself: not ours to count
            end
            local corpse = corpses[guid]
            if not corpse then
                corpse = { creature = creature, items = {}, quest = {}, names = {} }
                corpses[guid] = corpse
                order[#order + 1] = guid
            end
            if type(amount) ~= "number" or amount < 1 then
                amount = nil   -- the client names the corpse but not its share of the slot
            end
            if money then
                shares[guid] = amount or 0
            elseif item and not ns.Plain(quest) then
                if not amount then
                    -- The slot's quantity, split between the corpses it names: what the window holds is counted
                    -- once, not once per corpse.
                    local nth = (j + 1) / 2
                    amount = math.max(1, math.floor(quantity / named) + (nth <= quantity % named and 1 or 0))
                end
                corpse.items[item] = (corpse.items[item] or 0) + amount
            elseif item then
                -- Not a drop like the others: only who has the quest sees it. Counted apart (QuestChances).
                corpse.quest[item] = (corpse.quest[item] or 0) + (amount or quantity)
                corpse.names[item] = type(link) == "string" and link:match("%[(.-)%]") or nil
            end
        end
    end
    -- Coin: the window's text gives the total. With one corpse it is that corpse's; with several, the shares the
    -- client names per corpse are taken only if they add up to that total, else the coin of these corpses is unknown.
    local shareTotal = 0
    for _, amount in pairs(shares or {}) do
        shareTotal = shareTotal + amount
    end
    local changed = false
    local map, x, y = Place()   -- one window, one place: the corpses it names lie within reach of where we stand
    for _, guid in ipairs(order) do
        if MarkSeen(guid) then
            local copper
            if not shares then
                copper = 0
            elseif windowCopper and #order == 1 then
                copper = windowCopper
            elseif windowCopper and shareTotal == windowCopper then
                copper = shares[guid] or 0
            end
            Record.Corpse(ns.db.own, corpses[guid].creature, copper, corpses[guid].items, map, x, y)
            changed = true
            local held = LootText(corpses[guid].items)
            if copper and copper > 0 then
                held = (held and (held .. ", ") or "") .. CoinText(copper)
            end
            if next(corpses[guid].quest) then
                held = (held and (held .. ", ") or "") .. ns.L.questItems:format(LootText(corpses[guid].quest))
            end
            QuestChances(corpses[guid].creature, corpses[guid].quest, corpses[guid].names)
            ns.Log("m", CreatureText(guid, corpses[guid].creature) .. ns.L.colon .. (held or ns.L.nothing))
        end
    end
    if changed then
        ns.Touch()
    end
end

-- Events ---------------------------------------------------------------------

local lootRead = false   -- the open loot window has been read: the game may announce one window twice

local function OnSpellcast(event, unit, cast, spell)
    spell, cast = ns.Plain(spell), ns.Plain(cast)
    if unit ~= "player" or type(spell) ~= "number" then
        return
    end
    if spell == DISENCHANT then
        if event == "UNIT_SPELLCAST_START" then
            destroy = { bags = Bags(), t = GetTime(), cast = cast }
        elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
            if destroy then
                destroy.done = true
                if not destroy.loot and destroy.early and GetTime() - destroy.earlyAt <= EARLY_LOOT then
                    destroy.loot = destroy.early
                end
                ResolveDisenchant()
            end
        elseif destroy and not OtherCast(destroy.cast, cast) then
            destroy = nil
        end
    elseif GatherKind(spell) then
        if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_SUCCEEDED" then
            -- The start for a cast with a bar; the end also covers one without.
            if not gather or gather.cast ~= cast then
                gather = { kind = GatherKind(spell), t = GetTime(), cast = cast }
            end
        elseif gather and not OtherCast(gather.cast, cast) then
            gather = nil
        end
    elseif ByName(NOT_A_DROP, spell) then
        if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_SUCCEEDED" then
            if not taking or cast == nil or taking.cast ~= cast then
                taking = { t = GetTime(), cast = cast, skin = ByName(NOT_A_DROP, spell) == "skin" }
            elseif not taking.taken then
                taking.t = GetTime()   -- the window follows the end of the cast, however long the cast took
            end
            -- Else its window opened before the cast was reported as done: this report announces no other one.
        elseif taking and not OtherCast(taking.cast, cast) then
            taking = nil
        end
    elseif event == "UNIT_SPELLCAST_START" then
        local started = CraftStarted(spell)
        if started then
            started.cast = cast
        end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        if ns.db.own.c[spell] then
            CraftSucceeded(spell)
        end
    else
        CraftFailed(spell, cast)
    end
end

function Scan.Init()
    LoadSeen()
    LoadQuestItems()
    local frame = CreateFrame("Frame")
    for _, event in ipairs({
        "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED", "SKILL_LINES_CHANGED",
        "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_FAILED_QUIET",
        "UNIT_SPELLCAST_INTERRUPTED", "LOOT_READY", "LOOT_CLOSED", "BAG_UPDATE_DELAYED",
    }) do
        if event:sub(1, 14) == "UNIT_SPELLCAST" and frame.RegisterUnitEvent then
            -- Our own casts only: unfiltered, the game sends those of every unit in sight.
            pcall(frame.RegisterUnitEvent, frame, event, "player")
        else
            pcall(frame.RegisterEvent, frame, event)
        end
    end
    frame:SetScript("OnEvent", function(_, event, ...)
        if event:sub(1, 14) == "UNIT_SPELLCAST" then
            OnSpellcast(event, ...)
        elseif event == "LOOT_CLOSED" then
            lootRead = false
        elseif event == "LOOT_READY" then
            local pending = PendingDisenchant()
            if pending and not pending.loot then
                LootOpened(pending)
                ResolveDisenchant()
            elseif gather and GatherLoot() then
                lootRead = true
            elseif not lootRead and not pending and (ns.Try(GetNumLootItems) or 0) > 0 then
                -- Only a window that shows its content is read: an announcement that comes before it must not
                -- use up the one reading of this window.
                lootRead = true
                if taking and not taking.taken and GetTime() - taking.t <= GATHER_TIMEOUT then
                    taking.taken = true
                    if taking.skin then
                        SkinLoot()
                    end
                else
                    CorpseLoot()
                end
            end
        elseif event == "BAG_UPDATE_DELAYED" then
            if PendingDisenchant() then
                ResolveDisenchant()
            end
        else
            Debounce("colours", SCAN_DELAY, Scan.Colours)
        end
    end)
end
