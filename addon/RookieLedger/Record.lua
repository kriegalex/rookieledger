-- Record.lua: one account's observations, and the text form guild sync sends.
--
-- A record is { rev, t, b, c, s, d }: a change counter, the time and game build of the last change, and
--   c[recipe] = { profession, lo0, hi0, lo1, hi1, lo2, hi2, lo3, hi3 }
--       the lowest and highest skill at which the recipe showed each colour (0 orange, 1 yellow, 2 green, 3 grey;
--       0 = never seen in that colour)
--   s["recipe:skill:colour"] = { crafts, skillUps }
--   d[item] = { l = item level, q = quality, k = class (2 weapon, 4 armor), n = disenchants,
--               m = { [material] = { quantity, times } } }
-- Only numbers: a record holds no name and no text. The server reads the same shape from the saved file
-- (server/ledger_common.py checks the same bounds).
--
-- Every value only ever grows (a range widens, a count goes up), so two versions of a record merge by taking the
-- wider range and the larger count, and a part of a record can be sent alone. Our own record also keeps
--   lr[line key] = the change counter at which that line last changed ("c<recipe>", the s key, "d<item>")
--   lr0          = lines without an entry in lr changed at or before this counter
-- which is what lets guild sync send only the lines a member is missing. The server ignores both.
--
-- Text form, records separated by ";" and fields by ",":
--   h,build,time   c,recipe,profession,lo0,hi0,...,hi3   s,recipe,skill,colour,crafts,ups
--   d,item,level,quality,class,n   m,item,material,quantity,times
local _, ns = ...

local Record = {}
ns.Record = Record

local MAX_ID = 9999999
local MAX_SKILL = 600
local MAX_COUNT = 1000000
local MAX_LINES = 6000
Record.MAX_REV = 1000000000   -- as the server: a change counter above this is not a real one
Record.MAX_TEXT = 80000       -- what guild sync carries of one record (400 messages); the app uploads all of it

-- Notes that a line of our own record changes with the next change counter.
local function Mark(rec, key)
    if rec.lr then
        rec.lr[key] = rec.rev + 1
    end
end

function Record.New()
    return { rev = 0, t = 0, b = 0, c = {}, s = {}, d = {} }
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
    if changed then
        Mark(rec, "c" .. recipe)
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
    Mark(rec, key)
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
    for material, quantity in pairs(loot) do
        local m = entry.m[material]
        if not m then
            m = { 0, 0 }
            entry.m[material] = m
        end
        m[1] = m[1] + quantity
        m[2] = m[2] + 1
    end
    Mark(rec, "d" .. item)
end

-- Adds what part knows to rec: the wider range, the larger count. Both are checked records (Record.Parse).
function Record.Merge(rec, part)
    rec.t, rec.b = part.t, part.b
    for recipe, theirs in pairs(part.c) do
        local ours = rec.c[recipe]
        if not ours then
            rec.c[recipe] = theirs
        else
            ours[1] = theirs[1]
            for lo = 2, 8, 2 do
                if theirs[lo] > 0 and (ours[lo] == 0 or theirs[lo] < ours[lo]) then
                    ours[lo] = theirs[lo]
                end
                ours[lo + 1] = math.max(ours[lo + 1], theirs[lo + 1])
            end
        end
    end
    for key, theirs in pairs(part.s) do
        local ours = rec.s[key]
        if not ours then
            rec.s[key] = theirs
        else
            ours[1], ours[2] = math.max(ours[1], theirs[1]), math.max(ours[2], theirs[2])
        end
    end
    for item, theirs in pairs(part.d) do
        local ours = rec.d[item]
        if not ours then
            rec.d[item] = theirs
        else
            ours.l, ours.q, ours.k, ours.n = theirs.l, theirs.q, theirs.k, math.max(ours.n, theirs.n)
            for material, m in pairs(theirs.m) do
                local mine = ours.m[material]
                if not mine then
                    ours.m[material] = m
                else
                    mine[1], mine[2] = math.max(mine[1], m[1]), math.max(mine[2], m[2])
                end
            end
        end
    end
end

local function SortedKeys(t)
    local keys = {}
    for key in pairs(t) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
        if type(a) == type(b) then
            return a < b
        end
        return tostring(a) < tostring(b)
    end)
    return keys
end

-- The text form of rec, at most MAX_TEXT long: what does not fit is left out, colours first, then disenchants, then
-- crafts. With since, only the lines of our own record that changed after that change counter.
function Record.Serialize(rec, since)
    local out = { ("h,%d,%d"):format(rec.b or 0, rec.t or 0) }
    local size = #out[1]
    local lr = rec.lr or {}
    local function Changed(key)
        return not since or (lr[key] or 0) > since
    end
    local function Add(line)
        size = size + #line + 1
        if size > Record.MAX_TEXT then
            return false
        end
        out[#out + 1] = line
        return true
    end
    local full = false
    for _, recipe in ipairs(SortedKeys(rec.c)) do
        if not full and Changed("c" .. recipe) then
            full = not Add("c," .. recipe .. "," .. table.concat(rec.c[recipe], ","))
        end
    end
    for _, item in ipairs(SortedKeys(rec.d)) do
        if not full and Changed("d" .. item) then
            local entry = rec.d[item]
            full = not Add(("d,%d,%d,%d,%d,%d"):format(item, entry.l, entry.q, entry.k, entry.n))
            for _, material in ipairs(SortedKeys(entry.m)) do
                if not full then
                    full = not Add(("m,%d,%d,%d,%d"):format(item, material, entry.m[material][1], entry.m[material][2]))
                end
            end
        end
    end
    for _, key in ipairs(SortedKeys(rec.s)) do
        local recipe, skill, colour = key:match("^(%d+):(%d+):(%d)$")
        if recipe and not full and Changed(key) then
            full = not Add(("s,%s,%s,%s,%d,%d"):format(recipe, skill, colour, rec.s[key][1], rec.s[key][2]))
        end
    end
    return table.concat(out, ";")
end

-- A whole number between lo and hi, or nil.
local function Int(text, lo, hi)
    if type(text) ~= "string" or not text:match("^%d+$") or #text > 10 then
        return nil
    end
    local n = tonumber(text)
    if n < lo or n > hi then
        return nil
    end
    return n
end

local PARSERS = {}

function PARSERS.h(rec, f)
    local build, t = Int(f[2], 0, MAX_ID * 100), Int(f[3], 0, 4294967295)
    if #f ~= 3 or not build or not t then
        return false
    end
    rec.b, rec.t = build, t
    return true
end

function PARSERS.c(rec, f)
    if #f ~= 11 then
        return false
    end
    local recipe, profession = Int(f[2], 1, MAX_ID), Int(f[3], 1, MAX_ID)
    if not recipe or not profession or rec.c[recipe] then
        return false
    end
    local entry = { profession }
    for colour = 0, 3 do
        local lo, hi = Int(f[4 + colour * 2], 0, MAX_SKILL), Int(f[5 + colour * 2], 0, MAX_SKILL)
        if not lo or not hi or lo > hi or (lo == 0) ~= (hi == 0) then
            return false
        end
        entry[2 + colour * 2], entry[3 + colour * 2] = lo, hi
    end
    rec.c[recipe] = entry
    return true
end

function PARSERS.s(rec, f)
    if #f ~= 6 then
        return false
    end
    local recipe, skill, colour = Int(f[2], 1, MAX_ID), Int(f[3], 1, MAX_SKILL), Int(f[4], 0, 3)
    local crafts, ups = Int(f[5], 1, MAX_COUNT), Int(f[6], 0, MAX_COUNT)
    if not (recipe and skill and colour and crafts and ups) or ups > crafts * 5 then
        return false
    end
    local key = recipe .. ":" .. skill .. ":" .. colour
    if rec.s[key] then
        return false
    end
    rec.s[key] = { crafts, ups }
    return true
end

function PARSERS.d(rec, f)
    if #f ~= 6 then
        return false
    end
    local item, level, quality = Int(f[2], 1, MAX_ID), Int(f[3], 1, 1000), Int(f[4], 2, 4)
    local class, n = Int(f[5], 2, 4), Int(f[6], 1, MAX_COUNT)
    if not (item and level and quality and class and n) or class == 3 or rec.d[item] then
        return false
    end
    rec.d[item] = { l = level, q = quality, k = class, n = n, m = {} }
    return true
end

function PARSERS.m(rec, f)
    if #f ~= 5 then
        return false
    end
    local item, material = Int(f[2], 1, MAX_ID), Int(f[3], 1, MAX_ID)
    local quantity, times = Int(f[4], 1, MAX_COUNT * 20), Int(f[5], 1, MAX_COUNT)
    local entry = item and rec.d[item]
    if not (entry and material and quantity and times) or entry.m[material] then
        return false
    end
    if times > entry.n or quantity < times or quantity > times * 20 then
        return false
    end
    entry.m[material] = { quantity, times }
    return true
end

-- The record a text describes, or nil if any part of it is not what Serialize writes.
function Record.Parse(text)
    if type(text) ~= "string" or #text > Record.MAX_TEXT then
        return nil
    end
    local rec = Record.New()
    local lines = 0
    for line in text:gmatch("[^;]+") do
        lines = lines + 1
        if lines > MAX_LINES then
            return nil
        end
        local fields = {}
        for field in line:gmatch("[^,]+") do
            fields[#fields + 1] = field
        end
        local parser = PARSERS[fields[1]]
        if not parser or (lines == 1) ~= (fields[1] == "h") or not parser(rec, fields) then
            return nil
        end
    end
    if lines == 0 then
        return nil
    end
    return rec
end
