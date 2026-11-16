-- Sync.lua: passes records between guild members, in hidden addon messages on the guild channel only.
--
-- Every client keeps the newest record it has seen of each account (RookieLedgerDB.peers) and can hand any of them
-- on, so a record reaches members who were never online together with its author. Messages:
--   H,<id>,<rev>[,<id>,<rev>...]   "I hold these records at these change counters"; the first pair is the sender's own
--   Q,<holder>,<id>,<have>         "<holder>, send the record of <id>; I hold it at change counter <have>" (0: not at all)
--   P,<id>,<rev>,<base>,<part>,<parts>,<text>   one piece of a record's text form (Record.Serialize), heard by everyone.
--                                  base 0: the whole record. Otherwise only the lines changed since <base>, of use to
--                                  whoever holds the record at <base> or later.
-- A client that hears of a newer record waits a few seconds before asking, and does not ask while the record is
-- already on its way to someone else: one transfer serves every listener. Only a record's author knows which lines
-- changed when, so only the author answers with a part; anyone else sends the whole record.
--
-- The server allows a prefix about 10 messages at once and 1 more per second; the queue stays under that, and waits
-- while the client refuses addon messages (encounters, battlegrounds).
-- A record is only numbers, checked by Record.Parse before it is kept. The upload token is never sent.
--
-- Nobody can prove who wrote a record, so a guild member could send a made-up one under someone else's id. Two limits:
-- a change counter above Record.MAX_REV is refused, and an author who hears its own id at a counter it never reached
-- moves past that counter and sends its real record again. Records are kept per guild: what was received in one
-- guild is not announced in another.
--
-- The sender of a message is a character, so a member who watches could tie a record id to a player. Gathering places
-- are therefore sent an hour late (Record.Release): a record never says where its author is or just was.
local _, ns = ...

local Sync = {}
ns.Sync = Sync

local Record = ns.Record
local PREFIX = ns.PREFIX
local CHUNK = 200             -- text per D message (255 bytes less the header)
local MAX_PARTS = 400
local MAX_PEERS = 300
local PAIRS_PER_HELLO = 12
local HELLO_AFTER_LOGIN = 30
local HELLO_AFTER_CHANGE = 300
local HELLO_EVERY = 1800
local TRANSFER_TIMEOUT = 120  -- no asking for a record that was requested or seen passing this recently
local SERVE_AGAIN = 60
local BUCKET_CAP, BUCKET_RATE = 6, 1
local LOCKDOWN_CHECK = 3
local PUMP_EVERY = 0.5

local RESULT = Enum and Enum.SendAddonMessageResult or {}
local R_SUCCESS = RESULT.Success or 0
local R_THROTTLE = RESULT.AddonMessageThrottle or 3
local R_CHANNEL_THROTTLE = RESULT.ChannelThrottle or 8
local R_NOT_IN_GUILD = RESULT.NotInGuild or 10
local R_LOCKDOWN = RESULT.AddOnMessageLockdown or 11

local ChatInfo = C_ChatInfo or {}

local queue = {}
local pumping = false
local tokens, lastFill, waitUntil = BUCKET_CAP, 0, 0
local incoming = {}   -- [id] = { rev, base, parts, got = {}, n, t }: a record being received
local busy = {}       -- [id] = time a transfer of it that we can use was last asked for or heard
local served = {}     -- [id] = { t, rev, base }: what we last sent of it
local helloPending = false

-- A number that stands for the player's guild in this saved file only (the token is mixed in), or nil while the
-- guild is not known: not in one, or its name has not loaded yet.
local guildName, guildKey
local function GuildKey()
    if ns.Try(IsInGuild) ~= true then
        return nil
    end
    local name = ns.Plain((ns.Try(GetGuildInfo, "player")))
    if type(name) ~= "string" or name == "" then
        return nil
    end
    if name ~= guildName then
        local text, h = ns.db.token .. name, 5381
        for i = 1, #text do
            h = (h * 33 + text:byte(i)) % 4294967296
        end
        guildName, guildKey = name, h
    end
    return guildKey
end

local function Enabled()
    return ns.db.sync and GuildKey() ~= nil
end

-- Sending --------------------------------------------------------------------

local function Pump()
    local now = GetTime()
    tokens = math.min(BUCKET_CAP, tokens + (now - lastFill) * BUCKET_RATE)
    lastFill = now
    while queue[1] and tokens >= 1 and now >= waitUntil do
        if not ns.db.sync or ns.Try(IsInGuild) ~= true then
            queue = {}
            return
        end
        if not GuildKey() or ns.Try(ChatInfo.InChatMessagingLockdown) == true then
            waitUntil = now + LOCKDOWN_CHECK   -- the guild's name is loading, or the client holds addon messages back
            return
        end
        local ok, result = pcall(ChatInfo.SendAddonMessage, PREFIX, queue[1], "GUILD")
        result = ns.Plain(result)
        if ok and (result == R_THROTTLE or result == R_CHANNEL_THROTTLE) then
            tokens, waitUntil = 0, now + 3
            return
        end
        if ok and result == R_LOCKDOWN then
            waitUntil = now + LOCKDOWN_CHECK
            return
        end
        if ok and result == R_NOT_IN_GUILD then
            queue = {}
            return
        end
        -- Sent, or refused for a reason waiting does not cure: either way this message leaves the queue.
        table.remove(queue, 1)
        tokens = tokens - 1
        if not ok or not (result == nil or result == true or result == R_SUCCESS) then
            return
        end
    end
end

-- The pump only runs while something waits to be sent.
local function Tick()
    Pump()
    if queue[1] then
        C_Timer.After(PUMP_EVERY, Tick)
    else
        pumping = false
    end
end

local function Send(message)
    queue[#queue + 1] = message
    if not pumping then
        pumping = true
        C_Timer.After(0.1, Tick)
    end
end

-- What we hold ---------------------------------------------------------------

-- The record of id we may hand on in this guild.
local function Held(id)
    if id == ns.db.id then
        return ns.db.own
    end
    local rec = ns.db.peers[id]
    return rec and rec.guild == GuildKey() and rec or nil
end

local function Hello()
    if ns.db.sync and Record.Release(ns.db.own, time()) then
        ns.Touch()   -- gathering places old enough to be shared: a change like any other
    end
    helloPending = false
    if not Enabled() then
        return
    end
    local key = GuildKey()
    local pairsList = {}
    for id, rec in pairs(ns.db.peers) do
        if type(rec.g) ~= "table" then
            rec.g = {}   -- kept by a version without gathering, which noted the guild under this name
        end
        if rec.guild == nil then
            rec.guild = key   -- kept by a version that did not note the guild: this one
        end
        if rec.guild == key then
            pairsList[#pairsList + 1] = id .. "," .. rec.rev
        end
    end
    table.sort(pairsList)
    local own = ns.db.id .. "," .. ns.db.own.rev
    local i = 1
    repeat
        local parts = { "H", own }
        for j = i, math.min(i + PAIRS_PER_HELLO - 1, #pairsList) do
            parts[#parts + 1] = pairsList[j]
        end
        Send(table.concat(parts, ","))
        i = i + PAIRS_PER_HELLO
    until i > #pairsList
end

local function ScheduleHello(delay)
    if helloPending then
        return
    end
    helloPending = true
    C_Timer.After(delay, Hello)
end

function Sync.OwnChanged()
    if ns.db and ns.db.sync and Sync.ready then
        ScheduleHello(HELLO_AFTER_CHANGE)
    end
end

-- Sends the record of id to someone who holds it at change counter have.
local function Serve(id, have)
    local rec = Held(id)
    if not rec or rec.rev < 1 or have >= rec.rev then
        return
    end
    -- Only our own record can be sent in part, and only from a counter since which every change is known.
    local base = 0
    if id == ns.db.id and have > 0 and have >= (rec.lr0 or Record.MAX_REV) then
        base = have
    end
    local now = GetTime()
    local last = served[id]
    if last and now - last.t < SERVE_AGAIN and last.rev == rec.rev and last.base <= base then
        return   -- what just went out already held all of this
    end
    served[id] = { t = now, rev = rec.rev, base = base }
    local text = Record.Serialize(rec, base > 0 and base or nil)
    local parts = math.max(1, math.ceil(#text / CHUNK))
    for part = 1, parts do
        Send(("P,%s,%d,%d,%d,%d,%s"):format(id, rec.rev, base, part, parts, text:sub((part - 1) * CHUNK + 1, part * CHUNK)))
    end
end

-- Receiving ------------------------------------------------------------------

local function TrimPeers()
    local ids = {}
    for id in pairs(ns.db.peers) do
        ids[#ids + 1] = id
    end
    if #ids <= MAX_PEERS then
        return
    end
    table.sort(ids, function(a, b) return (ns.db.peers[a].at or 0) < (ns.db.peers[b].at or 0) end)
    for i = 1, #ids - MAX_PEERS do
        ns.db.peers[ids[i]] = nil
    end
end

local function Wanted(id, rev)
    local held = ns.db.peers[id]
    return id ~= ns.db.id and rev > (held and held.rev or 0)
end

-- A change counter as text: digits, at most Record.MAX_REV.
local function Rev(text)
    if type(text) ~= "string" or not text:match("^%d+$") or #text > 10 then
        return nil
    end
    local n = tonumber(text)
    return n <= Record.MAX_REV and n or nil
end

-- Someone names our own record at a change counter we never reached: a made-up copy, or the saved file was put back
-- from an older one. Either way ours is the real one: move past that counter and let it be sent whole.
local function Outbid(rev)
    local own = ns.db.own
    if rev > own.rev and rev < Record.MAX_REV then
        own.rev = rev
        own.lr0 = rev + 1
        ns.Touch()
    end
end

local function OnHello(fields)
    local holder = fields[2]
    for i = 2, #fields - 1, 2 do
        local rev = Rev(fields[i + 1])
        if fields[i] == ns.db.id and rev then
            Outbid(rev)
        end
    end
    if holder == ns.db.id then
        return
    end
    for i = 2, #fields - 1, 2 do
        local id, rev = fields[i], Rev(fields[i + 1])
        if id:match("^%x%x%x%x%x%x%x%x$") and rev and Wanted(id, rev) then
            -- Wait a little: someone else may ask first, and the answer reaches us as well.
            C_Timer.After(2 + math.random() * 10, function()
                if Enabled() and Wanted(id, rev) and not (busy[id] and GetTime() - busy[id] < TRANSFER_TIMEOUT) then
                    busy[id] = GetTime()
                    local held = ns.db.peers[id]
                    Send(("Q,%s,%s,%d"):format(holder, id, held and held.rev or 0))
                end
            end)
        end
    end
end

local function OnData(id, rev, base, part, parts, text)
    rev, base, part, parts = Rev(rev), Rev(base), tonumber(part), tonumber(parts)
    if not (rev and base and part and parts) or rev < 1 or base >= rev or parts < 1 or parts > MAX_PARTS
        or part < 1 or part > parts or #text > CHUNK then
        return
    end
    if id == ns.db.id then
        Outbid(rev)
        return
    end
    local key = GuildKey()
    if not key or not Wanted(id, rev) then
        return
    end
    local held = ns.db.peers[id]
    if base > 0 and not (held and held.rev >= base) then
        return   -- a part for someone who holds more of this record than we do: we ask for ours
    end
    local now = GetTime()
    busy[id] = now
    local buffer = incoming[id]
    if buffer and now - buffer.t < TRANSFER_TIMEOUT and (rev < buffer.rev
        or (rev == buffer.rev and (base ~= buffer.base or parts ~= buffer.parts))) then
        return   -- another transfer of it is arriving: one passing at the same time must not restart it
    end
    if not buffer or buffer.rev ~= rev or buffer.base ~= base or buffer.parts ~= parts then
        buffer = { rev = rev, base = base, parts = parts, got = {}, n = 0 }
        incoming[id] = buffer
    end
    buffer.t = now
    if not buffer.got[part] then
        buffer.got[part] = text
        buffer.n = buffer.n + 1
    end
    if buffer.n < parts then
        return
    end
    incoming[id] = nil
    local rec = Record.Parse(table.concat(buffer.got))
    if not rec then
        return
    end
    if base > 0 then
        held = ns.db.peers[id]
        if not (held and held.rev >= base and held.rev < rev) then
            return
        end
        Record.Merge(held, rec)
        rec = held
    end
    rec.rev = rev
    rec.at = time()
    rec.guild = key
    ns.db.peers[id] = rec
    TrimPeers()
end

local function OnMessage(text)
    local kind = text:sub(1, 2)
    if kind == "P," then
        local id, rev, base, part, parts, payload = text:match("^P,(%x%x%x%x%x%x%x%x),(%d+),(%d+),(%d+),(%d+),(.*)$")
        if id then
            OnData(id, rev, base, part, parts, payload)
        end
        return
    end
    local fields = {}
    for field in text:gmatch("[^,]+") do
        fields[#fields + 1] = field
    end
    if kind == "H," and #fields >= 3 and #fields % 2 == 1 then
        OnHello(fields)
    elseif kind == "Q," and #fields == 4 and fields[2] == ns.db.id and Rev(fields[4]) then
        Serve(fields[3], Rev(fields[4]))
    end
end

function Sync.Init()
    ns.Try(ChatInfo.RegisterAddonMessagePrefix, PREFIX)
    lastFill = GetTime()
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("CHAT_MSG_ADDON")
    frame:SetScript("OnEvent", function(_, _, prefix, text, channel)
        text = ns.Plain(text)
        if prefix == PREFIX and channel == "GUILD" and type(text) == "string" and ns.db.sync then
            OnMessage(text)
        end
    end)
    local function Periodic()
        ScheduleHello(1)
        C_Timer.After(HELLO_EVERY, Periodic)
    end
    C_Timer.After(HELLO_AFTER_LOGIN + math.random() * 20, Periodic)
    Sync.ready = true
end
