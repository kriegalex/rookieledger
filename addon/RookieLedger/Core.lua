-- Core.lua: saved data, the upload token, texts and the /ledger command.
--
-- RookieLedgerDB (one per WoW account) holds:
--   token   32 hex digits, made here once. The companion app reads it from the saved file and sends it with every
--           upload; the site accepts uploads only for tokens its owner has registered. It never goes out in game.
--   id      8 hex digits naming this account's record in guild sync and on the site. Not a character name.
--   own     this account's record (see Record.lua), peers[id] the records received from guild members.
local ADDON, ns = ...

ns.ADDON = ADDON
ns.PREFIX = "RookieLedger"
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
        loaded = "recording recipe colours, skill-ups, disenchants and what veins and herbs give, and where. /ledger for details.",
        first = "to add your data to the guild site, give your token to the guild's ledger keeper: /ledger token",
        status = "%d recipes with a colour, %d crafts, %d disenchants, %d veins and herbs gathered; %d guild records received; guild sync %s.",
        on = "on", off = "off",
        token = "Your token (Ctrl+C to copy). Give it to the guild's ledger keeper, to nobody else:",
        tokenChat = "token: %s",
        syncOn = "guild sync on.", syncOff = "guild sync off: nothing is sent or received in game.",
        help = "/ledger (status) | /ledger token | /ledger sync on|off",
        skipped = "a skill bonus is active (racial or item): colours are not recorded for this profession while it lasts.",
    },
    frFR = {
        loaded = "note la couleur des recettes, les points de compétence, les désenchantements et ce que donnent filons et plantes, et où. /ledger pour le détail.",
        first = "pour ajouter vos données au site de la guilde, donner votre jeton au responsable du registre : /ledger token",
        status = "%d recettes avec une couleur, %d fabrications, %d désenchantements, %d filons et plantes récoltés ; %d registres de guilde reçus ; synchronisation de guilde %s.",
        on = "activée", off = "désactivée",
        token = "Votre jeton (Ctrl+C pour copier). À donner au responsable du registre de la guilde, à personne d'autre :",
        tokenChat = "jeton : %s",
        syncOn = "synchronisation de guilde activée.", syncOff = "synchronisation de guilde désactivée : rien n'est envoyé ni reçu en jeu.",
        help = "/ledger (état) | /ledger token | /ledger sync on|off",
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
    if db.sync == nil then
        db.sync = true
    end
    if type(db.own) ~= "table" then
        db.own = ns.Record.New()
    end
    local own = db.own
    for _, section in ipairs({ "c", "s", "d", "g" }) do
        if type(own[section]) ~= "table" then
            own[section] = {}
        end
    end
    for _, counter in ipairs({ "rev", "t", "b" }) do
        if type(own[counter]) ~= "number" then
            own[counter] = 0
        end
    end
    if type(own.lr) ~= "table" or type(own.lr0) ~= "number" then
        own.lr, own.lr0 = {}, own.rev   -- see Record.lua: which lines changed when is known from here on
    end
    if type(own.hold) ~= "table" then
        own.hold = {}
    end
    if type(db.peers) ~= "table" then
        db.peers = {}
    end
    ns.db = db
    return fresh
end

-- Marks our record as changed: the companion app uploads it after the next logout, guild sync announces it.
function ns.Touch()
    local own = ns.db.own
    own.rev = own.rev + 1
    own.t = time()
    own.b = ns.build
    if ns.Sync then
        ns.Sync.OwnChanged()
    end
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
    local crafts, disenchants, gathers = 0, 0, 0
    for _, node in pairs(own.g) do
        gathers = gathers + node.n
    end
    for _, counts in pairs(own.s) do
        crafts = crafts + counts[1]
    end
    for _, item in pairs(own.d) do
        disenchants = disenchants + item.n
    end
    ns.Print(ns.L.status, Count(own.c), crafts, disenchants, gathers, Count(ns.db.peers), ns.db.sync and ns.L.on or ns.L.off)
end

local function Command(text)
    local word, arg = (text or ""):lower():match("^%s*(%S*)%s*(%S*)")
    if word == "" then
        Status()
    elseif word == "token" or word == "jeton" then
        ShowToken()
    elseif word == "sync" and (arg == "on" or arg == "off") then
        ns.db.sync = arg == "on"
        ns.Print(ns.db.sync and ns.L.syncOn or ns.L.syncOff)
        if ns.db.sync then
            ns.Sync.OwnChanged()
        end
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
        ns.Sync.Init()
        if ns.fresh then
            ns.Print(ns.L.loaded)
            ns.Print(ns.L.first)
        end
    end
end)
