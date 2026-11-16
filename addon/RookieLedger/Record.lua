-- Record.lua: one account's observations.
--
-- A record is { rev, t, b, c, s, d, g, m }: a change counter, the time and game build of the last change, and
--   c[recipe] = { profession, lo0, hi0, lo1, hi1, lo2, hi2, lo3, hi3 }
--       the lowest and highest skill at which the recipe showed each colour (0 orange, 1 yellow, 2 green, 3 grey;
--       0 = never seen in that colour)
--   s["recipe:skill:colour"] = { crafts, skillUps }
--   d[item] = { l = item level, q = quality, k = class (2 weapon, 4 armor), n = disenchants,
--               m = { [material] = { quantity, times } } }
--   g[node] = { k = kind (1 mining, 2 herbalism), n = gathers, m = { [material] = { quantity, times } },
--               p = { ["map:x:y"] = gathers there } }
--       node is the game's id of the vein or herb, map its map id, x and y the place on that map in thousandths
--   m[creature] = { n = corpses looted, cn = those whose coin is known, c = their coin in copper,
--                   i = { [item] = { quantity, corpses that held it } } }
--       creature is the game's id of the kind of monster
-- Only numbers: a record holds no name and no text. Every value only ever grows. Nothing of it is sent in game: the
-- game writes it to the saved file, and the companion app uploads that file to the guild site, where
-- server/ledger_common.py checks the same shape and the same bounds.
local _, ns = ...

local Record = {}
ns.Record = Record

local MAX_PLACES = 2000   -- per kind of node: past that, gathers still count but no new place is noted
local NEAR = 8            -- thousandths of a map: two gathers this close are the same vein or herb
local MAX_ITEMS = 5000    -- per kind of creature

function Record.New()
    return { rev = 0, t = 0, b = 0, c = {}, s = {}, d = {}, g = {}, m = {} }
end

-- Notes that recipe showed colour at skill. True when that widened a range.
function Record.Observe(rec, recipe, profession, colour, skill)
    local entry = rec.c[recipe]
    local changed = false
    if not entry then
        entry = { profession, 0, 0, 0, 0, 0, 0, 0, 0 }
        rec.c[recipe] = entry
        changed = true
    elseif entry[1] ~= profession then
        entry[1] = profession
        changed = true
    end
    local lo = 2 + colour * 2
    if entry[lo] == 0 or skill < entry[lo] then
        entry[lo] = skill
        changed = true
    end
    if skill > entry[lo + 1] then
        entry[lo + 1] = skill
        changed = true
    end
    return changed
end

function Record.Craft(rec, recipe, skill, colour, ups)
    local key = recipe .. ":" .. skill .. ":" .. colour
    local counts = rec.s[key]
    if not counts then
        counts = { 0, 0 }
        rec.s[key] = counts
    end
    counts[1] = counts[1] + 1
    counts[2] = counts[2] + ups
end

-- Adds one loot to a { [item] = { quantity, times } } table. loot: { [item id] = quantity }.
local function AddLoot(into, loot, limit)
    local held = 0
    if limit then
        for _ in pairs(into) do
            held = held + 1
        end
    end
    for item, quantity in pairs(loot) do
        local counts = into[item]
        if not counts and (not limit or held < limit) then
            counts = { 0, 0 }
            into[item] = counts
            held = held + 1
        end
        if counts then
            counts[1] = counts[1] + quantity
            counts[2] = counts[2] + 1
        end
    end
end

-- loot: { [material item id] = quantity }
function Record.Disenchant(rec, item, level, quality, class, loot)
    local entry = rec.d[item]
    if not entry then
        entry = { l = level, q = quality, k = class, n = 0, m = {} }
        rec.d[item] = entry
    end
    entry.l, entry.q, entry.k = level, quality, class
    entry.n = entry.n + 1
    AddLoot(entry.m, loot)
end

-- loot: { [material item id] = quantity }; map, x, y: where the player stood (x, y in thousandths), or nil.
function Record.Gather(rec, node, kind, loot, map, x, y)
    local entry = rec.g[node]
    if not entry then
        entry = { k = kind, n = 0, m = {}, p = {} }
        rec.g[node] = entry
    end
    entry.k = kind
    entry.n = entry.n + 1
    AddLoot(entry.m, loot)
    if not map then
        return
    end
    -- The place already noted for this vein or herb, if we stood about there before; else a new one.
    local key, places = nil, 0
    for place in pairs(entry.p) do
        places = places + 1
        local pm, px, py = place:match("^(%d+):(%d+):(%d+)$")
        if tonumber(pm) == map and math.abs(tonumber(px) - x) <= NEAR and math.abs(tonumber(py) - y) <= NEAR then
            key = place
        end
    end
    if not key and places < MAX_PLACES then
        key = map .. ":" .. x .. ":" .. y
    end
    if key then
        entry.p[key] = (entry.p[key] or 0) + 1
    end
end

-- One looted corpse. copper: its coin, or nil when the loot window did not let us tell which corpse held how much;
-- loot: { [item id] = quantity }.
function Record.Corpse(rec, creature, copper, loot)
    local entry = rec.m[creature]
    if not entry then
        entry = { n = 0, cn = 0, c = 0, i = {} }
        rec.m[creature] = entry
    end
    entry.n = entry.n + 1
    if copper then
        entry.cn = entry.cn + 1
        entry.c = entry.c + copper
    end
    AddLoot(entry.i, loot, MAX_ITEMS)
end
