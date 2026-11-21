package main

var texts = map[string][2]string{ // English, French
	"nofile": {"No RookieLedger data found yet: install the addon, log in once and log out.\nIf WoW is in an unusual folder, start this program once with --wow-dir \"<World of Warcraft folder>\".\n",
		"Aucune donnée RookieLedger trouvée : installer l'add-on, se connecter une fois puis se déconnecter.\nSi WoW est dans un dossier inhabituel, lancer une fois ce programme avec --wow-dir \"<dossier World of Warcraft>\".\n"},
	"found":           {"Account %s, token: %s\n", "Compte %s, jeton : %s\n"},
	"refused":         {"  the site refused its last file: %s\n", "  le site a refusé son dernier fichier : %s\n"},
	"give":            {"Uploads start by themselves on a site open to all. If a site asks for the token, give it to that site's keeper.\n", "L'envoi commence tout seul sur un site ouvert à tous. Si un site demande le jeton, le donner au responsable de ce site.\n"},
	"running":         {"RookieLedger Sync is already running.", "RookieLedger Sync est déjà lancé."},
	"installed":       {"RookieLedger Sync is installed: it starts with your session and uploads the addon's data after each game session.", "RookieLedger Sync est installé : il démarre avec la session et envoie les données de l'add-on après chaque session de jeu."},
	"server":          {"Server", "Serveur"},
	"up":              {"reachable", "joignable"},
	"down":            {"not reachable", "injoignable"},
	"checking":        {"checking…", "vérification…"},
	"lastsync":        {"Last sync", "Dernière synchro"},
	"never":           {"nothing sent yet", "rien envoyé pour l'instant"},
	"gamedata":        {"Game data", "Données du jeu"},
	"accounts":        {"found for %d account(s)", "trouvées pour %d compte(s)"},
	"nodata":          {"not found", "introuvables"},
	"hint":            {"Install the RookieLedger addon, log in to the game once and log out.", "Installer l'add-on RookieLedger, se connecter une fois au jeu puis se déconnecter."},
	"date":            {"2 Jan 2006, 15:04", "02/01/2006 à 15:04"},
	"showwindow":      {"Show", "Afficher"},
	"hidewindow":      {"Hide", "Masquer"},
	"quit":            {"Quit", "Quitter"},
	"manual":          {"RookieLedger Sync uploads the addon's data after each game session while it runs. It does not start with your session: the icon's menu switches that on.", "RookieLedger Sync envoie les données de l'add-on après chaque session de jeu tant qu'il est lancé. Il ne démarre pas avec la session : le menu de l'icône l'active."},
	"autostart":       {"Start with Windows", "Démarrer avec Windows"},
	"startupsettings": {"Start with Windows: open the settings…", "Démarrer avec Windows : ouvrir les paramètres…"},
	"debug":           {"Show details (debug)", "Afficher les détails (débogage)"},
	"sitedown":        {"The site answered %d: it is down behind its front door. Nothing to do on your side, it is tried again by itself.", "Le site a répondu %d : il est arrêté derrière sa porte d'entrée. Rien à faire de votre côté, un nouvel essai se fait tout seul."},
	"nodns":           {"The site's name was not found: no internet connection, or a DNS problem.", "Le nom du site est introuvable : pas de connexion internet, ou un problème de DNS."},
	"nocert":          {"The connection to the site is not trusted: the computer's clock is wrong, or an antivirus or a proxy stands in between.", "La connexion au site n'est pas sûre : l'horloge de l'ordinateur est fausse, ou un antivirus ou un proxy s'interpose."},
	"timeout":         {"The site did not answer in time: a slow or cut connection, or a firewall.", "Le site n'a pas répondu à temps : connexion lente ou coupée, ou pare-feu."},
	"noconnect":       {"The site could not be reached: no connection, or a firewall or antivirus blocks this program.", "Le site est injoignable : pas de connexion, ou un pare-feu ou un antivirus bloque ce programme."},
	"daddress":        {"Uploads to ", "Envoi vers "},
	"dwaiting":        {"The site does not accept your token yet. If it registers tokens by hand, give its keeper the one /ledger token shows in game.", "Le site n'accepte pas encore votre jeton. S'il enregistre les jetons à la main, donner à son responsable celui que /ledger token affiche en jeu."},
	"dlog":            {"Log: ", "Journal : "},
	"dfolder":         {"Game: %s, %d account(s), %d with the addon's data.", "Jeu : %s, %d compte(s), dont %d avec les données de l'add-on."},
	"dnoaddon":        {" The RookieLedger addon is not in its Interface\\AddOns folder.", " L'add-on RookieLedger n'est pas dans son dossier Interface\\AddOns."},
	"dnologin":        {" The addon is installed: log in to the game once and log out.", " L'add-on est installé : se connecter une fois au jeu puis se déconnecter."},
	"dnologout":       {" The addon is installed but has saved nothing yet: enable it in the game's AddOns list, then log out.", " L'add-on est installé mais n'a encore rien enregistré : l'activer dans la liste des add-ons du jeu, puis se déconnecter."},
	"dnofolder":       {"Game: no World of Warcraft folder with a _forever_ folder was found. If it is in an unusual place, start this program once with --wow-dir \"<World of Warcraft folder>\".", "Jeu : aucun dossier World of Warcraft contenant un dossier _forever_ n'a été trouvé. S'il est à un endroit inhabituel, lancer une fois ce programme avec --wow-dir \"<dossier World of Warcraft>\"."},
	"dotherflavor":    {"%s holds %s, but not _forever_: WoW Forever is not installed there.", "%s contient %s, mais pas _forever_ : WoW Forever n'y est pas installé."},
	"dnotwow":         {"%s exists, but holds no game.", "%s existe, mais ne contient aucun jeu."},
	"dnogiven":        {"The folder given with --wow-dir does not exist: %s", "Le dossier donné avec --wow-dir n'existe pas : %s"},
	"noautostart":     {"RookieLedger Sync runs now, but could not be set to start with the session: ", "RookieLedger Sync fonctionne, mais le démarrage automatique n'a pas pu être installé : "},
}

func text(key string) string {
	if french() {
		return texts[key][1]
	}
	return texts[key][0]
}
