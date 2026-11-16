-- Scan.lua: reads what the game shows and notes it in our record.
--
-- Recipe colours: while one of our own profession windows is open, the colour of every learned recipe at the
--   current skill (C_TradeSkillUI.GetRecipeInfo().relativeDifficulty: 0 orange, 1 yellow, 2 green, 3 grey).
-- Skill-ups: for each craft of a recipe we have seen in a window, the skill and colour before it and the points gained.
-- Disenchants: the item that left the bags during a Disenchant cast, and what the loot window it opened held.
-- Gathering: after a Mining or Herb Gathering cast, the vein or herb the loot window names as its source, what it
--   held, and where on the map the player stood.
-- Monster loot: for every corpse a loot window names as a source, the kind of monster, the items of every quality
--   and the coin it held. Only while not in a group (there the window shows one member's share), only what is not
--   a quest item, and each corpse once.
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
    local changed = false
    for _, recipe in ipairs(type(ids) == "table" and ids or {}) do
        local colour, info = RecipeColour(recipe)
        if colour and info.learned and not info.isDummyRecipe and type(recipe) == "number" then
            if Record.Observe(ns.db.own, recipe, skillLine, colour, rank[1]) then
                changed = true
            end
        end
    end
    if changed then
        ns.Touch()
    end
end

-- Skill-ups ------------------------------------------------------------------

local craft   -- the craft under way: { recipe, skillLine, rank, colour, done }

local function ResolveCraft()
    local c = craft
    if not c or not c.done then
        return
    end
    craft = nil
    local rank = Ranks()[c.skillLine]
    if not rank or rank[2] ~= 0 then
        return
    end
    local ups = rank[1] - c.rank
    if ups < 0 or ups > 5 then
        return
    end
    Record.Craft(ns.db.own, c.recipe, c.rank, c.colour, ups)
    ns.Touch()
end

local function CraftStarted(recipe)
    ResolveCraft()   -- the previous craft of a queue
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
    return craft
end

local function CraftSucceeded(recipe)
    if not craft or craft.recipe ~= recipe or craft.done then
        -- No cast bar came first (an instant craft): take the state as it is now.
        if not CraftStarted(recipe) then
            return
        end
    end
    craft.done = true
    local mine = craft
    C_Timer.After(UPS_DELAY, function()
        if craft == mine then
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
    if craft and craft.recipe == recipe and not craft.done and not OtherCast(craft.cast, cast) then
        craft = nil
    end
end

-- Disenchants ----------------------------------------------------------------

local Container = C_Container or {}
local ItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local function ItemID(link)
    return type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
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
        local id = ItemID(ns.Plain(ns.Try(GetLootSlotLink, slot)))
        local _, _, quantity = ns.Try(GetLootSlotInfo, slot)
        quantity = ns.Plain(quantity)
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
end

-- Gathering ------------------------------------------------------------------

local SpellName = (C_Spell and C_Spell.GetSpellName) or GetSpellInfo
local gatherNames   -- [spell name] = kind: the higher ranks are other spells under the same name

-- 1 for a mining cast, 2 for a herb gathering one, nil for any other spell.
local function GatherKind(spell)
    if GATHER[spell] then
        return GATHER[spell]
    end
    if not gatherNames then
        gatherNames = {}
        for id, kind in pairs(GATHER) do
            local name = ns.Plain((ns.Try(SpellName, id)))
            if type(name) == "string" then
                gatherNames[name] = kind
            end
        end
    end
    local name = ns.Plain((ns.Try(SpellName, spell)))
    return type(name) == "string" and gatherNames[name] or nil
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
            local id = tonumber(source:match("^GameObject%-%d+%-%d+%-%d+%-%d+%-(%d+)%-"))
            if not id or (node and node ~= id) then
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
    return true
end

-- Monster loot ---------------------------------------------------------------

local MONEY_SLOT = (Enum and Enum.LootSlotType and Enum.LootSlotType.Money) or LOOT_SLOT_MONEY or 2
local MAX_SEEN = 2000
local seen, seenOrder = {}, {}   -- corpses already counted this session: a corpse opened again shows what was left

-- The coin a money slot's text names, in copper, read with the client's own "%d Gold" / "%d Silver" / "%d Copper".
local function Copper(text)
    if type(text) ~= "string" then
        return nil
    end
    local total, any = 0, false
    for format, worth in pairs({ [GOLD_AMOUNT or false] = 10000, [SILVER_AMOUNT or false] = 100, [COPPER_AMOUNT or false] = 1 }) do
        if type(format) == "string" then
            local pattern = format:gsub("([%^%$%(%)%.%[%]%*%+%-%?])", "%%%1"):gsub("%%d", "(%%d+)")
            local amount = tonumber((text:match(pattern)))
            if amount then
                total, any = total + amount * worth, true
            end
        end
    end
    return any and total or nil
end

-- A loot window that is neither a disenchant's nor a gather's: corpses, if every source it names is one.
local function CorpseLoot()
    if ns.Try(IsInGroup) == true or type(GetLootSourceInfo) ~= "function" then
        return
    end
    local corpses, order = {}, {}   -- [guid] = { creature, items = {}, copper }
    local windowCopper, shares = nil, nil
    for slot = 1, ns.Try(GetNumLootItems) or 0 do
        local sources = { ns.Try(GetLootSourceInfo, slot) }
        local _, name, quantity, _, _, _, quest = ns.Try(GetLootSlotInfo, slot)
        local item = ItemID(ns.Plain(ns.Try(GetLootSlotLink, slot)))
        local money = not item and ns.Plain(ns.Try(GetLootSlotType, slot)) == MONEY_SLOT
        if money then
            windowCopper, shares = Copper(ns.Plain(name)), {}
        end
        for j = 1, #sources, 2 do
            local guid, amount = ns.Plain(sources[j]), ns.Plain(sources[j + 1])
            local creature = type(guid) == "string" and tonumber(guid:match("^Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)%-"))
            if not creature then
                return   -- a chest, an item, or a source the client keeps to itself: not ours to count
            end
            local corpse = corpses[guid]
            if not corpse then
                corpse = { creature = creature, items = {} }
                corpses[guid] = corpse
                order[#order + 1] = guid
            end
            if type(amount) ~= "number" or amount < 1 then
                amount = type(ns.Plain(quantity)) == "number" and ns.Plain(quantity) or 1
            end
            if money then
                shares[guid] = amount
            elseif item and not ns.Plain(quest) then
                corpse.items[item] = (corpse.items[item] or 0) + amount
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
    for _, guid in ipairs(order) do
        if not seen[guid] then
            seen[guid] = true
            seenOrder[#seenOrder + 1] = guid
            if #seenOrder > MAX_SEEN then
                seen[table.remove(seenOrder, 1)] = nil
            end
            local copper
            if not shares then
                copper = 0
            elseif windowCopper and #order == 1 then
                copper = windowCopper
            elseif windowCopper and shareTotal == windowCopper then
                copper = shares[guid] or 0
            end
            Record.Corpse(ns.db.own, corpses[guid].creature, copper, corpses[guid].items)
            changed = true
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
            elseif not lootRead and not pending then
                lootRead = true
                CorpseLoot()
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
