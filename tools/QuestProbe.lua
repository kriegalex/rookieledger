-- QuestProbe.lua: asks the running game what it tells an addon about quest items and the quest log, and writes
-- the answers down. Like Probe.lua, it is a tool behind docs/client-behaviour.md, not part of the addon.
--
-- It finds out:
--   which quest-log functions this client has, and what they return for every quest in the log,
--   which loot slots the client flags as quest items, and what the item's own data says,
--   whether a quest objective's text names the item, so that the quest can be found from the item,
--   which events follow the looting of a quest item, and how the objectives change with them.
-- It records nothing in the ledger and sends nothing. It never registers for the combat log.
--
-- To use it, in the installed copy of the addon (World of Warcraft/_forever_/Interface/AddOns/RookieLedger):
--   1. copy this file there;
--   2. in RookieLedger.toc, add RookieLedgerQuestProbe to the SavedVariablesPerCharacter line and QuestProbe.lua
--      as the last line;
--   3. restart the game, loot quest items, then /reload: the lines are in RookieLedgerQuestProbe, in
--      WTF/Account/<account>/<realm>/<character>/SavedVariables/RookieLedger.lua.
-- To remove it, undo steps 1 and 2.
--
--   /questprobe           chat lines on or off (the log is kept either way)
--   /questprobe dump      writes the whole quest log down again
--   /questprobe clear     empties the log
local ADDON = ...

local MAX_LINES = 3000
local issecret = issecretvalue or function() return false end
local log, chat = nil, true
local started = GetTime and GetTime() or 0

local function S(value)
    if issecret(value) then
        return "<secret>"
    end
    return tostring(value)
end

local function Plain(value)
    if issecret(value) then
        return nil
    end
    return value
end

local function Log(text)
    local line = ("%s +%.1f %s"):format(date and date("%H:%M:%S") or "?", (GetTime and GetTime() or 0) - started, text)
    if log then
        log[#log + 1] = line
        if #log > MAX_LINES then
            for _ = 1, 500 do
                table.remove(log, 1)
            end
        end
    end
    if chat then
        print("|cffc8a2ffquest|r " .. text)
    end
end

-- The results of a call as one string: "a,b,c", "nothing", "absent" or the error.
local function Results(ok, ...)
    if not ok then
        return "ERROR " .. S((...))
    end
    local n = select("#", ...)
    if n == 0 then
        return "nothing"
    end
    local out = {}
    for i = 1, n do
        out[i] = S((select(i, ...)))
    end
    return table.concat(out, ",")
end

local function Call(f, ...)
    if type(f) ~= "function" then
        return "absent"
    end
    return Results(pcall(f, ...))
end

-- f(...) or nothing: absent functions and errors give nil.
local function Try(f, ...)
    if type(f) ~= "function" then
        return nil
    end
    local function pass(ok, ...)
        if ok then
            return ...
        end
    end
    return pass(pcall(f, ...))
end

local QL = C_QuestLog or {}

-- The quest log ----------------------------------------------------------------

-- { [quest id] = { title, objectives = { { text, type, finished, have, need } } } } read with the C_QuestLog
-- functions, or nil when this client lacks them.
local function ReadNew()
    local count = Plain(Try(QL.GetNumQuestLogEntries))
    if type(count) ~= "number" or type(QL.GetInfo) ~= "function" then
        return nil
    end
    local quests = {}
    for index = 1, count do
        local info = Try(QL.GetInfo, index)
        if type(info) == "table" and not Plain(info.isHeader) then
            local id = Plain(info.questID)
            if type(id) == "number" then
                local quest = { title = S(info.title), objectives = {} }
                local objectives = Try(QL.GetQuestObjectives, id)
                for j, o in ipairs(type(objectives) == "table" and objectives or {}) do
                    quest.objectives[j] = { text = S(o.text), type = S(o.type), finished = S(o.finished),
                        have = S(o.numFulfilled), need = S(o.numRequired) }
                end
                quests[id] = quest
            end
        end
    end
    return quests
end

-- The same with the functions of the older clients (GetQuestLogTitle, GetQuestLogLeaderBoard), or nil.
local function ReadOld()
    if type(GetNumQuestLogEntries) ~= "function" or type(GetQuestLogTitle) ~= "function" then
        return nil
    end
    local count = Plain(Try(GetNumQuestLogEntries))
    if type(count) ~= "number" then
        return nil
    end
    local quests = {}
    for index = 1, count do
        local title, _, _, isHeader, _, _, _, id = Try(GetQuestLogTitle, index)
        id = Plain(id)
        if not Plain(isHeader) and type(id) == "number" and id > 0 then
            local quest = { title = S(title), objectives = {} }
            for j = 1, Plain(Try(GetNumQuestLeaderBoards, index)) or 0 do
                local text, kind, finished = Try(GetQuestLogLeaderBoard, j, index)
                quest.objectives[j] = { text = S(text), type = S(kind), finished = S(finished), have = "?", need = "?" }
            end
            quests[id] = quest
        end
    end
    return quests
end

local function ObjectiveText(o)
    return ("%q type=%s finished=%s %s/%s"):format(o.text, o.type, o.finished, o.have, o.need)
end

local function Dump(label, quests)
    if not quests then
        Log(label .. ": these functions are absent")
        return
    end
    local n = 0
    for id, quest in pairs(quests) do
        n = n + 1
        Log(("%s quest %d %q"):format(label, id, quest.title))
        for j, o in ipairs(quest.objectives) do
            Log(("%s   objective %d: %s"):format(label, j, ObjectiveText(o)))
        end
    end
    Log(label .. ": " .. n .. " quests")
end

local previous   -- the last reading of the quest log, to tell what an event changed

-- Says what changed in the quest log since the last reading. why: what made us look.
local function Changes(why)
    local now = ReadNew() or ReadOld()
    if not now then
        return
    end
    local before = previous or {}
    previous = now
    for id, quest in pairs(now) do
        local old = before[id]
        if not old then
            Log(("%s: quest %d %q is new in the log"):format(why, id, quest.title))
        else
            for j, o in ipairs(quest.objectives) do
                local was = old.objectives[j]
                if not was or ObjectiveText(was) ~= ObjectiveText(o) then
                    Log(("%s: quest %d objective %d now %s (was %s)"):format(why, id, j, ObjectiveText(o),
                        was and ObjectiveText(was) or "absent"))
                end
            end
        end
    end
    for id, quest in pairs(before) do
        if not now[id] then
            Log(("%s: quest %d %q left the log"):format(why, id, quest.title))
        end
    end
end

-- Loot windows ---------------------------------------------------------------

local function Short(guid)
    guid = Plain(guid)
    if type(guid) ~= "string" then
        return S(guid)
    end
    local kind, _, _, _, _, id, spawn = strsplit("-", guid)
    if id and spawn then
        return kind .. " " .. id .. " " .. spawn
    end
    return guid
end

-- The objectives whose text holds name, as "quest 123 objective 2 (...)" each.
local function Matches(name)
    local found = {}
    for id, quest in pairs(ReadNew() or ReadOld() or {}) do
        for j, o in ipairs(quest.objectives) do
            if type(o.text) == "string" and o.text:find(name, 1, true) then
                found[#found + 1] = ("quest %d objective %d (%s)"):format(id, j, ObjectiveText(o))
            end
        end
    end
    return found
end

local lastWindow   -- the slots of the last window announced, as one string: a window is announced twice

local function LootReady()
    local n = Plain(Try(GetNumLootItems)) or 0
    local lines = {}
    for slot = 1, n do
        local link = Plain(Try(GetLootSlotLink, slot))
        local _, _, quantity, _, _, _, quest, questId, active = Try(GetLootSlotInfo, slot)
        local source = Try(GetLootSourceInfo, slot)
        lines[#lines + 1] = ("slot %d: %s x%s quest=%s questId=%s active=%s from %s"):format(slot, S(link):gsub("|", "||"),
            S(quantity), S(quest), S(questId), S(active), Short(source))
        if type(link) == "string" then
            local item = tonumber(link:match("item:(%d+)"))
            local name = link:match("%[(.-)%]")
            if Plain(quest) or Plain(questId) then
                lines[#lines + 1] = ("  item %s %q: GetItemInfoInstant=%s"):format(S(item), S(name),
                    Call((C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant, link))
                local found = name and Matches(name) or {}
                lines[#lines + 1] = ("  objectives naming it: %d"):format(#found)
                for _, match in ipairs(found) do
                    lines[#lines + 1] = "    " .. match
                end
            end
        end
    end
    local all = table.concat(lines, "\n")
    if all == lastWindow then
        return
    end
    lastWindow = all
    Log(("LOOT_READY %d slots"):format(n))
    for _, line in ipairs(lines) do
        Log(line)
    end
end

-- Events ---------------------------------------------------------------------

local EVENTS = {
    "QUEST_LOG_UPDATE", "UNIT_QUEST_LOG_CHANGED", "QUEST_WATCH_UPDATE", "QUEST_ACCEPTED", "QUEST_REMOVED",
    "QUEST_TURNED_IN", "QUEST_LOG_CRITERIA_UPDATE", "UI_INFO_MESSAGE", "LOOT_READY", "LOOT_CLOSED",
}
local quiet = { QUEST_LOG_UPDATE = true, LOOT_READY = true, LOOT_CLOSED = true }   -- not logged for themselves

local errors = {}

local function OnEvent(event, ...)
    if event == "LOOT_READY" then
        LootReady()
        return
    elseif event == "LOOT_CLOSED" then
        lastWindow = nil
        return
    end
    if not quiet[event] then
        Log(event .. " " .. Results(true, ...))
    end
    Changes(event)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= ADDON then
            return
        end
        if type(RookieLedgerQuestProbe) ~= "table" then
            RookieLedgerQuestProbe = {}
        end
        log = RookieLedgerQuestProbe
        local _, build, _, toc = GetBuildInfo()
        Log(("--- session: build %s interface %s"):format(S(build), S(toc)))
        local names = {}
        for _, name in ipairs({ "GetNumQuestLogEntries", "GetInfo", "GetQuestObjectives", "IsOnQuest", "IsComplete",
            "GetLogIndexForQuestID", "GetQuestIDForLogIndex", "ReadyForTurnIn", "UnitIsRelatedToActiveQuest" }) do
            names[#names + 1] = name .. "=" .. type(QL[name])
        end
        Log("C_QuestLog: " .. table.concat(names, " "))
        names = {}
        for _, name in ipairs({ "GetNumQuestLogEntries", "GetQuestLogTitle", "GetNumQuestLeaderBoards",
            "GetQuestLogLeaderBoard", "GetQuestLogSpecialItemInfo", "GetItemInfoInstant", "IsQuestItem" }) do
            names[#names + 1] = name .. "=" .. type(_G[name])
        end
        Log("globals: " .. table.concat(names, " "))
        -- Never the combat log.
        for _, name in ipairs(EVENTS) do
            local ok, result
            if name == "UNIT_QUEST_LOG_CHANGED" and frame.RegisterUnitEvent then
                ok, result = pcall(frame.RegisterUnitEvent, frame, name, "player")
            else
                ok, result = pcall(frame.RegisterEvent, frame, name)
            end
            Log(("register %s: %s%s"):format(name, ok and "ok" or "REFUSED", result ~= nil and (" (" .. S(result) .. ")") or ""))
        end
        return
    elseif event == "PLAYER_LOGIN" then
        Dump("C_QuestLog", ReadNew())
        Dump("old functions", ReadOld())
        previous = ReadNew() or ReadOld()
        return
    end
    local ok, problem = pcall(OnEvent, event, ...)
    if not ok and not errors[S(problem)] then
        errors[S(problem)] = true
        Log("ERROR in " .. event .. ": " .. S(problem))
    end
end)

SLASH_ROOKIELEDGERQUESTPROBE1 = "/questprobe"
SlashCmdList.ROOKIELEDGERQUESTPROBE = function(text)
    text = (text or ""):lower()
    if text:match("clear") then
        if log then
            for i = #log, 1, -1 do
                log[i] = nil
            end
        end
        print("|cffc8a2ffquest|r log cleared")
    elseif text:match("dump") then
        Dump("C_QuestLog", ReadNew())
        Dump("old functions", ReadOld())
    else
        chat = not chat
        print("|cffc8a2ffquest|r chat lines " .. (chat and "on" or "off") .. ", " .. (log and #log or 0) .. " lines in the log")
    end
end
