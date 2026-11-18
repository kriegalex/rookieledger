-- Probe.lua: asks the running game what it tells an addon about kills and corpses, and writes the answers down.
-- It is the tool behind docs/client-behaviour.md. It is not part of the addon and is in no release.
--
-- It finds out:
--   which of PARTY_KILL / UNIT_DIED can be registered and what they carry,
--   what CanLootUnit answers for a corpse right after the death, a little later, and once it is looted,
--   what UnitIsTapDenied says of a dead monster under the target or the mouse,
--   which corpse each loot window names, and which windows follow a Skinning or Pick Pocket cast.
-- It records nothing in the ledger and sends nothing. It never registers for the combat log.
--
-- To use it, in the installed copy of the addon (World of Warcraft/_forever_/Interface/AddOns/RookieLedger):
--   1. copy this file there;
--   2. in RookieLedger.toc, add RookieLedgerProbe to the SavedVariablesPerCharacter line
--      ("## SavedVariablesPerCharacter: RookieLedgerLocal, RookieLedgerProbe") and Probe.lua as the last line;
--   3. restart the game, play, then /reload: the lines are in RookieLedgerProbe, in
--      WTF/Account/<account>/<realm>/<character>/SavedVariables/RookieLedger.lua.
-- To remove it, undo steps 1 and 2. The game drops RookieLedgerProbe from the saved file by itself.
--
--   /ledgerprobe          chat lines on or off (the log is kept either way)
--   /ledgerprobe clear    empties the log
local ADDON = ...

local MAX_LINES = 3000
local DELAYS = { 0, 0.5, 2, 5 }   -- seconds after a death at which the corpse is asked about

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
        print("|cff88ccffprobe|r " .. text)
    end
end

-- "kind npc-id spawn" of a GUID, short enough for a chat line.
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

local function IsCreature(guid)
    guid = Plain(guid)
    return type(guid) == "string" and (guid:sub(1, 9) == "Creature-" or guid:sub(1, 8) == "Vehicle-")
end

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

-- What CanLootUnit answers for a GUID: "hasLoot,canLoot", "nothing", "absent" or the error.
local function Loot(guid)
    if type(CanLootUnit) ~= "function" then
        return "absent"
    end
    return Results(pcall(CanLootUnit, guid))
end

local function Call(f, ...)
    if type(f) ~= "function" then
        return "absent"
    end
    return Results(pcall(f, ...))
end

-- Deaths ---------------------------------------------------------------------

local asked = {}   -- [guid] = true once its follow-up questions are scheduled

local function Died(event, guid, attacker)
    local line = event .. " " .. Short(guid)
    if attacker ~= nil then
        -- Another player is not named: the log is meant to be read and shared.
        local me = Plain(attacker) ~= nil and Plain(attacker) == Plain(UnitGUID("player"))
        line = line .. " by " .. (me and "me" or (Plain(attacker) == nil and S(attacker) or "someone else"))
    end
    guid = Plain(guid)
    if guid and guid == Plain(UnitGUID("target")) then
        line = line .. " (my target, tapDenied=" .. Call(UnitIsTapDenied, "target") .. ")"
    end
    Log(line)
    if not IsCreature(guid) or asked[guid] then
        return
    end
    asked[guid] = true
    for _, delay in ipairs(DELAYS) do
        local function Ask()
            Log(("  %s after %.1fs: CanLootUnit=%s"):format(Short(guid), delay, Loot(guid)))
        end
        if delay == 0 then
            Ask()
        else
            C_Timer.After(delay, Ask)
        end
    end
end

-- Dead monsters under the target or the mouse --------------------------------

local lastSaid = {}   -- [guid] = the last line logged for it: the same answer is not repeated

local function Unit(unit)
    if Plain(UnitExists(unit)) ~= true or Plain(UnitIsPlayer(unit)) == true then
        return
    end
    local guid = Plain(UnitGUID(unit))
    if not IsCreature(guid) or Plain(UnitIsDead(unit)) ~= true then
        return
    end
    local line = ("%s dead %s: CanLootUnit=%s tapDenied=%s"):format(unit, Short(guid), Loot(guid),
        Call(UnitIsTapDenied, unit))
    if lastSaid[guid] ~= line then
        lastSaid[guid] = line
        Log(line)
    end
end

-- Loot windows ---------------------------------------------------------------

local windowGuids = {}

local function LootReady()
    local n = Plain(GetNumLootItems and GetNumLootItems()) or 0
    local seen, names = {}, {}
    for slot = 1, n do
        local sources = { pcall(GetLootSourceInfo, slot) }
        for j = 2, #sources, 2 do
            local guid = Plain(sources[j])
            if type(guid) == "string" and not seen[guid] then
                seen[guid] = true
                names[#names + 1] = Short(guid)
            end
        end
    end
    windowGuids = seen
    Log(("LOOT_READY %d slots from %s"):format(n, #names > 0 and table.concat(names, " / ") or "no named source"))
end

local function LootClosed()
    local guids = windowGuids
    windowGuids = {}
    for guid in pairs(guids) do
        if IsCreature(guid) then
            C_Timer.After(0.5, function()
                Log(("  %s after its window closed: CanLootUnit=%s"):format(Short(guid), Loot(guid)))
            end)
        end
    end
end

-- Skinning and Pick Pocket, so their windows can be told from a corpse's in the log.
local function Cast(unit, _, spell)
    spell = Plain(spell)
    if unit ~= "player" or type(spell) ~= "number" then
        return
    end
    local name = C_Spell and C_Spell.GetSpellName and Plain(C_Spell.GetSpellName(spell))
    if not name then
        return
    end
    for label, id in pairs({ Skinning = 8613, ["Pick Pocket"] = 921 }) do
        if name == Plain(C_Spell.GetSpellName(id)) then
            Log("cast " .. label .. " (" .. spell .. ")")
        end
    end
end

-- Events ---------------------------------------------------------------------

local errors = {}
local handlers = {
    PARTY_KILL = function(attacker, target) Died("PARTY_KILL", target, attacker) end,
    UNIT_DIED = function(guid) Died("UNIT_DIED", guid) end,
    PLAYER_TARGET_CHANGED = function() Unit("target") end,
    UPDATE_MOUSEOVER_UNIT = function() Unit("mouseover") end,
    LOOT_READY = LootReady,
    LOOT_CLOSED = LootClosed,
    UNIT_SPELLCAST_SUCCEEDED = Cast,
}

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= ADDON then
            return
        end
        if type(RookieLedgerProbe) ~= "table" then
            RookieLedgerProbe = {}
        end
        log = RookieLedgerProbe
        local _, build, _, toc = GetBuildInfo()
        Log(("--- session: build %s interface %s, CanLootUnit %s, UnitIsTapDenied %s"):format(S(build), S(toc),
            type(CanLootUnit), type(UnitIsTapDenied)))
        -- Never the combat log: this client is said to block an addon that registers for it.
        for name in pairs(handlers) do
            local ok, result
            if name == "UNIT_SPELLCAST_SUCCEEDED" and frame.RegisterUnitEvent then
                ok, result = pcall(frame.RegisterUnitEvent, frame, name, "player")
            else
                ok, result = pcall(frame.RegisterEvent, frame, name)
            end
            Log(("register %s: %s%s"):format(name, ok and "ok" or "REFUSED", result ~= nil and (" (" .. S(result) .. ")") or ""))
        end
        return
    end
    local ok, problem = pcall(handlers[event], ...)
    if not ok and not errors[S(problem)] then
        errors[S(problem)] = true
        Log("ERROR in " .. event .. ": " .. S(problem))
    end
end)

SLASH_ROOKIELEDGERPROBE1 = "/ledgerprobe"
SlashCmdList.ROOKIELEDGERPROBE = function(text)
    if (text or ""):lower():match("clear") then
        if log then
            for i = #log, 1, -1 do
                log[i] = nil
            end
        end
        print("|cff88ccffprobe|r log cleared")
    else
        chat = not chat
        print("|cff88ccffprobe|r chat lines " .. (chat and "on" or "off") .. ", " .. (log and #log or 0) .. " lines in the log")
    end
end
