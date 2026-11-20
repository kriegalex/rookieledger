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
--   log     the last things recorded, as the window shows them: { time, kind, text } each.
--   minimap where the minimap button sits and whether it is hidden (the table LibDBIcon keeps).
--   window  where the window was left.
--   tooltip the settings of the monster tooltip: off, and from, the lowest item quality it shows.
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
        announce = "%s loaded. /ledger for details.",
        loaded = "recording recipe colours, skill-ups, disenchants, gathering and monster loot. /ledger for details.",
        first = "to add your data to the RookieLedger site, install the companion app (see the addon's page). If a site asks for your token: /ledger token",
        status = "%d recipes observed, %d crafts, %d disenchants, %d veins and herbs gathered, %d corpses looted.",
        token = "Your token (Ctrl+C to copy). It is the key to your record: give it only to the keeper of a site that asks for it:",
        tokenChat = "token: %s",
        help = "/ledger (status) | /ledger show | /ledger tooltip | /ledger minimap | /ledger token",
        skipped = "a skill bonus is active (racial or item): colours are not recorded for this profession while it lasts.",
        rowC = "Recipes observed", rowS = "Crafts", rowD = "Disenchants", rowG = "Veins and herbs", rowM = "Corpses looted",
        session = "This session", total = "In total", recent = "Last recorded", logEmpty = "Nothing recorded yet.",
        hintLeft = "Left click: window", hintRight = "Right click: options",
        minimapOn = "minimap button shown.", minimapOff = "minimap button hidden. /ledger minimap brings it back.",
        minimapNone = "this copy of the addon has no minimap button (its libraries are missing). /ledger show opens the window.",
        optOpen = "Open the window", optMinimap = "Show the minimap button",
        optAbout = "Records what the game shows you while you play, for the RookieLedger site. /ledger show opens the window.",
        logColours = "Difficulty noted for %d recipes", logUp = "%s: +%d skill", logNoUp = "%s: no skill point",
        logDisenchant = "%s disenchanted: %s", vein = "Vein", herb = "Herb", creature = "creature %d", item = "item %d",
        recipe = "recipe %d", copper = "%d copper", nothing = "nothing", colon = ": ",
        questItems = "%s (quest item)",
        tipLooted = "looted %dx", tipQuest = "quest", tipCoin = "Coin", tipMore = "+%d more", tipAll = "All", percent = "%d%%",
        tooltipOn = "monster tooltips show what you looted from them.", tooltipOff = "monster tooltips no longer show loot. /ledger tooltip brings it back.",
        optTooltip = "Show what a monster gave you in its tooltip", optFrom = "Show items from:",
        quality1 = "Common", quality2 = "Uncommon", quality3 = "Rare", quality4 = "Epic",
    },
    frFR = {
        announce = "%s chargé. /ledger pour le détail.",
        loaded = "note la couleur des recettes, les points de compétence, les désenchantements, la récolte et le butin des monstres. /ledger pour le détail.",
        first = "pour ajouter vos données au site RookieLedger, installer l'application compagnon (voir la page de l'add-on). Si un site demande votre jeton : /ledger token",
        status = "%d recettes observées, %d fabrications, %d désenchantements, %d filons et plantes récoltés, %d cadavres fouillés.",
        token = "Votre jeton (Ctrl+C pour copier). C'est la clé de votre registre : à ne donner qu'au responsable d'un site qui le demande :",
        tokenChat = "jeton : %s",
        help = "/ledger (état) | /ledger show | /ledger tooltip | /ledger minimap | /ledger token",
        skipped = "un bonus de compétence est actif (racial ou objet) : les couleurs ne sont pas notées pour ce métier tant qu'il dure.",
        rowC = "Recettes observées", rowS = "Fabrications", rowD = "Désenchantements", rowG = "Filons et plantes", rowM = "Cadavres fouillés",
        session = "Cette session", total = "Au total", recent = "Derniers enregistrements", logEmpty = "Rien d'enregistré pour l'instant.",
        hintLeft = "Clic gauche : fenêtre", hintRight = "Clic droit : options",
        minimapOn = "bouton de la minicarte affiché.", minimapOff = "bouton de la minicarte masqué. /ledger minimap le fait revenir.",
        minimapNone = "cette copie de l'addon n'a pas de bouton de minicarte (ses bibliothèques manquent). /ledger show ouvre la fenêtre.",
        optOpen = "Ouvrir la fenêtre", optMinimap = "Afficher le bouton de la minicarte",
        optAbout = "Note ce que le jeu vous montre pendant que vous jouez, pour le site RookieLedger. /ledger show ouvre la fenêtre.",
        logColours = "Difficulté notée pour %d recettes", logUp = "%s : +%d compétence", logNoUp = "%s : pas de point de compétence",
        logDisenchant = "%s désenchanté : %s", vein = "Filon", herb = "Plante", creature = "créature %d", item = "objet %d",
        recipe = "recette %d", copper = "%d cuivre", nothing = "rien", colon = " : ",
        questItems = "%s (objet de quête)",
        tipLooted = "fouillé %d×", tipQuest = "quête", tipCoin = "Pièces", tipMore = "+%d de plus", tipAll = "Tout", percent = "%d %%",
        tooltipOn = "l'infobulle des monstres montre ce que vous y avez trouvé.", tooltipOff = "l'infobulle des monstres ne montre plus le butin. /ledger tooltip le fait revenir.",
        optTooltip = "Montrer dans l'infobulle d'un monstre ce qu'il vous a donné", optFrom = "Afficher les objets à partir de :",
        quality1 = "Commun", quality2 = "Inhabituel", quality3 = "Rare", quality4 = "Épique",
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

-- Version --------------------------------------------------------------------

-- The version the .toc names, "dev" for a copy of the repository: the packager writes the version in place of a
-- marker when it builds a release.
local function Version()
    local version = ns.Plain(ns.Try(C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata, ADDON, "Version"))
    if type(version) ~= "string" or version == "" or version:find("@", 1, true) then
        return "dev"
    end
    return version
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
    for _, section in ipairs({ "c", "s", "d", "g", "m", "q" }) do
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
    for _, part in ipairs({ "log", "minimap", "window", "tooltip" }) do
        if type(here[part]) ~= "table" then
            here[part] = {}
        end
    end
    ns.here = here
    return fresh
end

-- The log and the counts of this session --------------------------------------

local MAX_LOG = 50
ns.session = {}   -- [kind] = how many were recorded since login: c, s, d, g, m as the sections of the record

-- Notes that something was recorded: n of kind, told by text (the window shows it as it is). Kept per character,
-- on this computer only.
function ns.Log(kind, text, n)
    ns.session[kind] = (ns.session[kind] or 0) + (n or 1)
    local log = ns.here.log
    log[#log + 1] = { time(), kind, text }
    while #log > MAX_LOG do
        table.remove(log, 1)
    end
    if ns.UI then
        ns.UI.Refresh()
    end
end

-- Marks our record as changed: the companion app uploads it after the next logout.
-- How long the record took to make, for a site that takes uploads from anyone and has only this to tell a record
-- that was played from one that was typed: f is the time of its first change, a the seconds of play its changes
-- took. A change counts for the time since the change before it, IDLE at most; the first of a session, which has
-- none before it, for FIRST. A record begun by an older version has no f: it gets none, since what it already
-- holds took time nobody counted.
local IDLE, FIRST = 300, 60
local touched   -- time() of this session's last change

function ns.Touch()
    local own = ns.db.own
    local now = time()
    own.rev = own.rev + 1
    if own.rev == 1 then
        own.f = now
    end
    own.a = (own.a or 0) + (touched and math.max(0, math.min(now - touched, IDLE)) or FIRST)
    touched = now
    own.t = now
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

-- What the record holds, by section: recipes with a colour, crafts, disenchants, gathers, corpses.
function ns.Totals()
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
    return { c = Count(own.c), s = crafts, d = disenchants, g = gathers, m = corpses }
end

local function Status()
    local t = ns.Totals()
    ns.Print(ns.L.status, t.c, t.s, t.d, t.g, t.m)
end

local function Command(text)
    local word = (text or ""):lower():match("^%s*(%S*)")
    if word == "" then
        Status()
    elseif word == "token" or word == "jeton" then
        ShowToken()
    elseif (word == "show" or word == "fenetre" or word == "fenêtre") and ns.UI then
        ns.UI.Toggle()
    elseif word == "minimap" and ns.UI then
        ns.UI.ToggleMinimap()
    elseif (word == "tooltip" or word == "infobulle") and ns.Tooltip then
        ns.Tooltip.Toggle()
        if ns.UI then
            ns.UI.Refresh()
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
        ns.version = Version()
        ns.fresh = InitDB()
        SLASH_ROOKIELEDGER1, SLASH_ROOKIELEDGER2 = "/ledger", "/rookieledger"
        SlashCmdList.ROOKIELEDGER = Command
    elseif ns.db then
        ns.Scan.Init()
        if ns.Tooltip then
            pcall(ns.Tooltip.Init)   -- a client without that tooltip loses it, and nothing else
        end
        if ns.UI then
            ns.UI.Init()
        end
        ns.Print(ns.L.announce, ns.version)
        if ns.fresh then
            ns.Print(ns.L.loaded)
            ns.Print(ns.L.first)
        end
    end
end)
