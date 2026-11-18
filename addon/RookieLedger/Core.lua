-- Core.lua: saved data, the upload token, texts and the /ledger command.
--
-- RookieLedgerDB (one per WoW account) holds:
--   token   32 hex digits, made here once. The companion app reads it from the saved file and sends it with every
--           upload; the site accepts uploads only for tokens its owner has registered. It never goes out in game.
--   id      8 hex digits naming this account's record on the site. Not a character name.
--   own     this account's record (see Record.lua).
-- RookieLedgerLocal (one per character) holds what only this computer needs and the companion app never reads:
--   seen    the corpses counted last, so that one opened again after a reload or a new login is not counted twice
--           (see Scan.lua). They are the game's own names for them, which tell the realm and when each appeared:
--           the reason they are kept here and not in the record.
--   next    the place in seen that the next corpse takes.
-- The addon sends nothing, in game or out of it: the game writes these tables to files at logout.
local ADDON, ns = ...

ns.ADDON = ADDON
ns.FORMAT = 1

local issecretvalue = issecretvalue or function() return false end

-- A value the client lets addons read, or nil.
function ns.Plain(value)
    if issecretvalue(value) then
        return nil
    end
    return value
end

local function Results(ok, ...)
    if ok then
        return ...
    end
end

-- Calls f if it exists and returns its results, nothing on an error.
function ns.Try(f, ...)
    if type(f) ~= "function" then
        return nil
    end
    return Results(pcall(f, ...))
end

-- Texts ----------------------------------------------------------------------

local TEXTS = {
    enUS = {
        loaded = "recording recipe colours, skill-ups, disenchants, gathering and monster loot. /ledger for details.",
        first = "to add your data to the guild site, give your token to the guild's ledger keeper: /ledger token",
        status = "%d recipes with a colour, %d crafts, %d disenchants, %d veins and herbs gathered, %d corpses looted.",
        token = "Your token (Ctrl+C to copy). Give it to the guild's ledger keeper, to nobody else:",
        tokenChat = "token: %s",
        help = "/ledger (status) | /ledger token",
        skipped = "a skill bonus is active (racial or item): colours are not recorded for this profession while it lasts.",
    },
    frFR = {
        loaded = "note la couleur des recettes, les points de compétence, les désenchantements, la récolte et le butin des monstres. /ledger pour le détail.",
        first = "pour ajouter vos données au site de la guilde, donner votre jeton au responsable du registre : /ledger token",
        status = "%d recettes avec une couleur, %d fabrications, %d désenchantements, %d filons et plantes récoltés, %d cadavres fouillés.",
        token = "Votre jeton (Ctrl+C pour copier). À donner au responsable du registre de la guilde, à personne d'autre :",
        tokenChat = "jeton : %s",
        help = "/ledger (état) | /ledger token",
        skipped = "un bonus de compétence est actif (racial ou objet) : les couleurs ne sont pas notées pour ce métier tant qu'il dure.",
    },
}
local L = TEXTS[GetLocale and GetLocale() or "enUS"] or TEXTS.enUS
ns.L = setmetatable({}, { __index = function(_, key) return L[key] or TEXTS.enUS[key] or key end })

function ns.Print(text, ...)
    if select("#", ...) > 0 then
        text = text:format(...)
    end
    print("|cffe6b422RookieLedger|r : " .. text)
end

-- Token and id ---------------------------------------------------------------

-- Hex digits from the client's random numbers mixed with things another player cannot see (clock, uptime, the
-- character's GUID). Lua 5.1 has no better source; 128 bits that are only ever compared with a list of registered
-- tokens do not need one.
local function RandomHex(groups, salt)
    local seed = table.concat({ tostring(time and time() or 0), tostring(GetTime and GetTime() or 0),
        tostring(debugprofilestop and debugprofilestop() or 0), tostring(UnitGUID and UnitGUID("player") or ""), salt }, "|")
    local h = 5381
    local out = {}
    for i = 1, groups do
        for j = 1, #seed do
            h = (h * 33 + seed:byte(j) + i) % 4294967296
        end
        out[i] = ("%04x"):format((math.random(0, 65535) + h) % 65536)
    end
    return table.concat(out)
end

local function InitDB()
    local db = RookieLedgerDB
    if type(db) ~= "table" then
        db = {}
        RookieLedgerDB = db
    end
    -- A saved table of another format keeps its token, id and records: the token is registered on the site and the
    -- observations cannot be made again. A format change converts the fields here instead of starting over.
    db.v = ns.FORMAT
    local fresh = false
    if type(db.token) ~= "string" or not db.token:match("^%x+$") or #db.token ~= 32 then
        db.token = RandomHex(8, "token")
        fresh = true
    end
    if type(db.id) ~= "string" or not db.id:match("^%x+$") or #db.id ~= 8 then
        db.id = RandomHex(2, "id")
    end
    if type(db.own) ~= "table" then
        db.own = ns.Record.New()
    end
    local own = db.own
    for _, section in ipairs({ "c", "s", "d", "g", "m" }) do
        if type(own[section]) ~= "table" then
            own[section] = {}
        end
    end
    for _, counter in ipairs({ "rev", "t", "b" }) do
        if type(own[counter]) ~= "number" then
            own[counter] = 0
        end
    end
    -- What versions with guild sync kept: other members' records and the bookkeeping of what was sent.
    db.peers, db.sync, own.lr, own.lr0, own.hold = nil, nil, nil, nil, nil
    ns.db = db
    local here = RookieLedgerLocal
    if type(here) ~= "table" then
        here = {}
        RookieLedgerLocal = here
    end
    here.v = ns.FORMAT
    ns.here = here
    return fresh
end

-- Marks our record as changed: the companion app uploads it after the next logout.
function ns.Touch()
    local own = ns.db.own
    own.rev = own.rev + 1
    own.t = time()
    own.b = ns.build
end

-- Commands -------------------------------------------------------------------

local function Count(t)
    local n = 0
    for _ in pairs(t) do
        n = n + 1
    end
    return n
end

local function ShowToken()
    ns.Print(ns.L.tokenChat, ns.db.token)
    if not StaticPopupDialogs or not StaticPopup_Show then
        return
    end
    StaticPopupDialogs.ROOKIELEDGER_TOKEN = StaticPopupDialogs.ROOKIELEDGER_TOKEN or {
        text = ns.L.token,
        button1 = OKAY or "OK",
        hasEditBox = true,
        editBoxWidth = 280,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
        OnShow = function(self)
            local box = (self.GetEditBox and self:GetEditBox()) or self.editBox or self.EditBox
            if box then
                box:SetText(ns.db.token)
                box:SetFocus()
                box:HighlightText()
            end
        end,
        EditBoxOnEscapePressed = function(self)
            self:GetParent():Hide()
        end,
    }
    StaticPopup_Show("ROOKIELEDGER_TOKEN")
end

local function Status()
    local own = ns.db.own
    local crafts, disenchants, gathers, corpses = 0, 0, 0, 0
    for _, creature in pairs(own.m) do
        corpses = corpses + creature.n
    end
    for _, node in pairs(own.g) do
        gathers = gathers + node.n
    end
    for _, counts in pairs(own.s) do
        crafts = crafts + counts[1]
    end
    for _, item in pairs(own.d) do
        disenchants = disenchants + item.n
    end
    ns.Print(ns.L.status, Count(own.c), crafts, disenchants, gathers, corpses)
end

local function Command(text)
    local word = (text or ""):lower():match("^%s*(%S*)")
    if word == "" then
        Status()
    elseif word == "token" or word == "jeton" then
        ShowToken()
    else
        ns.Print(ns.L.help)
    end
end
ns.Command = Command

-- Start ----------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(_, event, name)
    if event == "ADDON_LOADED" then
        if name ~= ADDON then
            return
        end
        local _, build = GetBuildInfo()
        ns.build = tonumber(build) or 0
        ns.fresh = InitDB()
        SLASH_ROOKIELEDGER1, SLASH_ROOKIELEDGER2 = "/ledger", "/rookieledger"
        SlashCmdList.ROOKIELEDGER = Command
    elseif ns.db then
        ns.Scan.Init()
        if ns.fresh then
            ns.Print(ns.L.loaded)
            ns.Print(ns.L.first)
        end
    end
end)
