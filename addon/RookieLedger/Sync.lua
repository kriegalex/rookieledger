-- Sync.lua: passes records between guild members, in hidden addon messages on the guild channel only.
--
-- Every client keeps the newest record it has seen of each account (RookieLedgerDB.peers) and can hand any of them
-- on, so a record reaches members who were never online together with its author. Messages:
--   H,<id>,<rev>[,<id>,<rev>...]   "I hold these records at these change counters"; the first pair is the sender's own
--   R,<holder>,<id>                "<holder>, send the record of <id>"
--   D,<id>,<rev>,<part>,<parts>,<text>   one piece of a record's text form (Record.Serialize), heard by everyone
-- A client that hears of a newer record waits a few seconds before asking, and does not ask while the record is
-- already on its way to someone else: one transfer serves every listener.
--
-- The server allows a prefix about 10 messages at once and 1 more per second; the queue stays under that.
-- A record is only numbers, checked by Record.Parse before it is kept. The upload token is never sent.
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
local HELLO_AFTER_CHANGE = 120
local HELLO_EVERY = 1800
local TRANSFER_TIMEOUT = 120  -- no asking for a record that was requested or seen passing this recently
local SERVE_AGAIN = 60
local BUCKET_CAP, BUCKET_RATE = 6, 1

local RESULT = Enum and Enum.SendAddonMessageResult or {}
local R_SUCCESS = RESULT.Success or 0
local R_THROTTLE = RESULT.AddonMessageThrottle or 3
local R_CHANNEL_THROTTLE = RESULT.ChannelThrottle or 8

local ChatInfo = C_ChatInfo or {}

local queue = {}
local tokens, lastFill, waitUntil = BUCKET_CAP, 0, 0
local incoming = {}   -- [id] = { rev, parts, got = {}, n, t }: a record being received
local busy = {}       -- [id] = time a transfer of it was last asked for or heard
local served = {}     -- [id] = time we last sent it
local helloPending = false

local function Enabled()
    return ns.db.sync and ns.Try(IsInGuild) == true
end

-- Sending --------------------------------------------------------------------

local function Pump()
    local now = GetTime()
    tokens = math.min(BUCKET_CAP, tokens + (now - lastFill) * BUCKET_RATE)
    lastFill = now
    while queue[1] and tokens >= 1 and now >= waitUntil do
        if not Enabled() then
            queue = {}
            return
        end
        local ok, result = pcall(ChatInfo.SendAddonMessage, PREFIX, queue[1], "GUILD")
        result = ns.Plain(result)
        if ok and (result == R_THROTTLE or result == R_CHANNEL_THROTTLE) then
            tokens, waitUntil = 0, now + 3
            return
        end
        -- Sent, or refused for a reason waiting does not cure: either way the message leaves the queue.
        table.remove(queue, 1)
        tokens = tokens - 1
        if not ok or not (result == nil or result == true or result == R_SUCCESS) then
            queue = {}
            return
        end
    end
end

local function Send(message)
    queue[#queue + 1] = message
end

-- What we hold ---------------------------------------------------------------

local function Held(id)
    if id == ns.db.id then
        return ns.db.own
    end
    return ns.db.peers[id]
end

local function Hello()
    helloPending = false
    if not Enabled() then
        return
    end
    local pairsList = {}
    for id, rec in pairs(ns.db.peers) do
        pairsList[#pairsList + 1] = id .. "," .. rec.rev
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

local function Serve(id)
    local rec = Held(id)
    local now = GetTime()
    if not rec or rec.rev < 1 or (served[id] and now - served[id] < SERVE_AGAIN) then
        return
    end
    local text = Record.Serialize(rec)
    if #text > Record.MAX_TEXT then
        return
    end
    served[id] = now
    local parts = math.max(1, math.ceil(#text / CHUNK))
    for part = 1, parts do
        Send(("D,%s,%d,%d,%d,%s"):format(id, rec.rev, part, parts, text:sub((part - 1) * CHUNK + 1, part * CHUNK)))
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
    local held = Held(id)
    return id ~= ns.db.id and rev > (held and held.rev or 0)
end

local function OnHello(fields)
    local holder = fields[2]
    if holder == ns.db.id then
        return
    end
    for i = 2, #fields - 1, 2 do
        local id, rev = fields[i], tonumber(fields[i + 1])
        if id:match("^%x%x%x%x%x%x%x%x$") and rev and Wanted(id, rev) then
            -- Wait a little: someone else may ask first, and the answer reaches us as well.
            C_Timer.After(2 + math.random() * 10, function()
                if Enabled() and Wanted(id, rev) and not (busy[id] and GetTime() - busy[id] < TRANSFER_TIMEOUT) then
                    busy[id] = GetTime()
                    Send("R," .. holder .. "," .. id)
                end
            end)
        end
    end
end

local function OnData(id, rev, part, parts, text)
    rev, part, parts = tonumber(rev), tonumber(part), tonumber(parts)
    if not (rev and part and parts) or parts < 1 or parts > MAX_PARTS or part < 1 or part > parts or #text > CHUNK then
        return
    end
    local now = GetTime()
    busy[id] = now
    if not Wanted(id, rev) then
        return
    end
    local buffer = incoming[id]
    if buffer and rev < buffer.rev and now - buffer.t < TRANSFER_TIMEOUT then
        return   -- a newer version is arriving: an older one passing at the same time must not restart it
    end
    if not buffer or buffer.rev ~= rev or buffer.parts ~= parts then
        buffer = { rev = rev, parts = parts, got = {}, n = 0 }
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
    rec.rev = rev
    rec.at = time()
    ns.db.peers[id] = rec
    TrimPeers()
end

local function OnMessage(text)
    local kind = text:sub(1, 2)
    if kind == "D," then
        local id, rev, part, parts, payload = text:match("^D,(%x%x%x%x%x%x%x%x),(%d+),(%d+),(%d+),(.*)$")
        if id then
            OnData(id, rev, part, parts, payload)
        end
        return
    end
    local fields = {}
    for field in text:gmatch("[^,]+") do
        fields[#fields + 1] = field
    end
    if kind == "H," and #fields >= 3 and #fields % 2 == 1 then
        OnHello(fields)
    elseif kind == "R," and #fields == 3 and fields[2] == ns.db.id then
        Serve(fields[3])
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
    local function Tick()
        Pump()
        C_Timer.After(0.5, Tick)
    end
    Tick()
    local function Periodic()
        ScheduleHello(1)
        C_Timer.After(HELLO_EVERY, Periodic)
    end
    C_Timer.After(HELLO_AFTER_LOGIN + math.random() * 20, Periodic)
    Sync.ready = true
end
