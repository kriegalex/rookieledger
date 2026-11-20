package main

var texts = map[string][2]string{ // English, French
	"nofile": {"No RookieLedger data found yet: install the addon, log in once and log out.\nIf WoW is in an unusual folder, start this program once with --wow-dir \"<World of Warcraft folder>\".\n",
		"Aucune donnée RookieLedger trouvée : installer l'add-on, se connecter une fois puis se déconnecter.\nSi WoW est dans un dossier inhabituel, lancer une fois ce programme avec --wow-dir \"<dossier World of Warcraft>\".\n"},
	"found":       {"Account %s, token: %s\n", "Compte %s, jeton : %s\n"},
	"refused":     {"  the site refused its last file: %s\n", "  le site a refusé son dernier fichier : %s\n"},
	"give":        {"Uploads start by themselves on a site open to all. If a site asks for the token, give it to that site's keeper.\n", "L'envoi commence tout seul sur un site ouvert à tous. Si un site demande le jeton, le donner au responsable de ce site.\n"},
	"running":     {"RookieLedger Sync is already running.", "RookieLedger Sync est déjà lancé."},
	"installed":   {"RookieLedger Sync is installed: it starts with your session and uploads the addon's data after each game session.", "RookieLedger Sync est installé : il démarre avec la session et envoie les données de l'add-on après chaque session de jeu."},
	"server":      {"Server", "Serveur"},
	"up":          {"reachable", "joignable"},
	"down":        {"not reachable", "injoignable"},
	"checking":    {"checking…", "vérification…"},
	"lastsync":    {"Last sync", "Dernière synchro"},
	"never":       {"nothing sent yet", "rien envoyé pour l'instant"},
	"gamedata":    {"Game data", "Données du jeu"},
	"accounts":    {"found for %d account(s)", "trouvées pour %d compte(s)"},
	"nodata":      {"not found", "introuvables"},
	"hint":        {"Install the RookieLedger addon, log in to the game once and log out.", "Installer l'add-on RookieLedger, se connecter une fois au jeu puis se déconnecter."},
	"date":        {"2 Jan 2006, 15:04", "02/01/2006 à 15:04"},
	"showwindow":  {"Show", "Afficher"},
	"hidewindow":  {"Hide", "Masquer"},
	"quit":        {"Quit", "Quitter"},
	"noautostart": {"RookieLedger Sync runs now, but could not be set to start with the session: ", "RookieLedger Sync fonctionne, mais le démarrage automatique n'a pas pu être installé : "},
}

func text(key string) string {
	if french() {
		return texts[key][1]
	}
	return texts[key][0]
}
