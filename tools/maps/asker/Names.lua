-- Names.lua: asks the game for the names of the monsters the map page cannot name yet.
-- A tool of the map build (tools/maps/build_names.py), which writes this folder into the game with the list of
-- monsters to ask for (Ids.lua) and takes it out once every monster has a name. It is not part of the addon and is
-- in no release.
--
-- The game's tables hold no monster names: the server tells a name to the client the first time the client shows
-- that monster, and the client keeps it in its cache file, which is where the build reads names. Showing a tooltip
-- for a monster by its number alone is enough for the client to ask, so nobody has to go and meet each one. The
-- names come in the language of the client.
--
-- It asks by itself a few seconds after a character enters the world, says in the chat how many names came, and
-- does nothing else: it saves nothing and sends nothing to other players. The client writes its cache file as it
-- closes: leave the game before building again.
--
--   /ledgernames    asks again
local ids = RookieLedgerNamesIds or {}

local AT_ONCE, EVERY = 5, 0.5   -- monsters asked for per pass and seconds between two passes
local ANSWER = 3                -- seconds left to the server for the last answers
local START = 5                 -- seconds after entering the world

local tip = CreateFrame("GameTooltip", "RookieLedgerNamesTip", nil, "GameTooltipTemplate")
local busy = false

local function Say(text)
    print("|cff33ff99RookieLedger names|r: " .. text)
end

-- Shows the monster's tooltip out of sight. True when the client already has its name; else the client asks the
-- server for it, and has it at a later call.
local function Named(id)
    tip:SetOwner(WorldFrame, "ANCHOR_NONE")
    tip:SetHyperlink(("unit:Creature-0-0-0-0-%d-0000000000"):format(id))
    local line = _G["RookieLedgerNamesTipTextLeft1"]
    local text = line and line:GetText()
    tip:Hide()
    return text ~= nil and text ~= ""
end

-- Goes through the list AT_ONCE monsters at a time, then calls done(how many have a name).
local function Pass(done)
    local at, named = 0, 0
    local ticker
    ticker = C_Timer.NewTicker(EVERY, function()
        for _ = 1, AT_ONCE do
            at = at + 1
            if at > #ids then
                ticker:Cancel()
                return done(named)
            end
            if Named(ids[at]) then
                named = named + 1
            end
        end
    end)
end

local function Ask()
    if busy then
        return
    end
    if #ids == 0 then
        return Say("no monster to ask for.")
    end
    busy = true
    Say(("asking for %d monsters, about %d seconds."):format(#ids, 2 * math.ceil(#ids / AT_ONCE) * EVERY + ANSWER))
    Pass(function()
        C_Timer.After(ANSWER, function()
            Pass(function(named)
                busy = false
                Say(("%d of %d monsters have a name. Leave the game, then build the names again."):format(named, #ids))
            end)
        end)
    end)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function()
    C_Timer.After(START, Ask)
end)

SLASH_ROOKIELEDGERNAMES1 = "/ledgernames"
SlashCmdList.ROOKIELEDGERNAMES = Ask
