package main

var texts = map[string][2]string{ // English, French
	"nofile": {"No RookieLedger data found yet: install the addon, log in once and log out.\nIf WoW is in an unusual folder, start this program once with --wow-dir \"<World of Warcraft folder>\".\n",
		"Aucune donnée RookieLedger trouvée : installer l'add-on, se connecter une fois puis se déconnecter.\nSi WoW est dans un dossier inhabituel, lancer une fois ce programme avec --wow-dir \"<dossier World of Warcraft>\".\n"},
	"found":       {"Account %s, token: %s\n", "Compte %s, jeton : %s\n"},
	"refused":     {"  the site refused its last file: %s\n", "  le site a refusé son dernier fichier : %s\n"},
	"give":        {"Give the token to the guild's ledger keeper; uploads start once it is registered.\n", "Donner le jeton au responsable du registre de la guilde ; l'envoi commence une fois le jeton enregistré.\n"},
	"running":     {"RookieLedger Sync is already running.", "RookieLedger Sync est déjà lancé."},
	"installed":   {"RookieLedger Sync is installed: it starts with your session and uploads the addon's data after each game session.", "RookieLedger Sync est installé : il démarre avec la session et envoie les données de l'add-on après chaque session de jeu."},
	"noautostart": {"RookieLedger Sync runs now, but could not be set to start with the session: ", "RookieLedger Sync fonctionne, mais le démarrage automatique n'a pas pu être installé : "},
}

func text(key string) string {
	if french() {
		return texts[key][1]
	}
	return texts[key][0]
}
