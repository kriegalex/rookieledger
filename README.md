# RookieLedger

A World of Warcraft: Forever addon that records what the game shows you while you play, and a small companion app
that uploads it to your guild's site. The guild then learns together what guides get wrong on Forever:

- at which skill a recipe turns yellow, green and grey;
- how often a yellow or green recipe really gives a skill point;
- what disenchanting an item of a given quality and item level really gives;
- what a vein or a herb really gives, and where they are found;
- what each kind of monster really drops, and how much coin;
- how often a monster really gives the item a quest asks for.

## What is recorded

Only numbers the game client shows you:

- the colour of each recipe at your current skill, read while your profession window is open;
- per recipe and colour, how many crafts you made and how many gave a skill point;
- per disenchanted item: its quality, class and item level, and the materials received;
- per kind of vein or herb you gathered: how often, the materials received, and the places (map and position on it)
  where you gathered it;
- per kind of monster you looted alone: how many corpses, their coin, and every item they held (quest items left out);
- per quest item a kind of monster gave you: the quest and the objective that asked for it, how many corpses of that
  monster you looted while the quest still wanted the item, and how many of them held it.

A quest item only drops for who has the quest, which is why it is counted apart: against the corpses looted while
the quest wanted it, not against all of them. The addon learns which quest that is from your quest log, the first
time the item shows in a corpse; that first corpse is not counted, so that the drop that made the item known does
not raise its rate. Of your quests, the record holds only the number of a quest that asked for such an item.

No character name, account name, realm, guild name, chat, gold total or inventory is recorded, and no time other
than that of the record's last change. A record is named by a random 8-digit id made on first login. A record only
grows: a skill range widens, a count goes up.

Beside the record, the addon keeps one small file per character that never leaves your computer. The companion app
does not read it. It holds:

- the game's own names for the last 500 corpses it counted, so that a corpse opened again after a reload or a new
  login is not counted twice. Those names tell the realm and when each monster appeared, which is why they are kept
  out of the record;
- the last 50 things recorded as the window shows them, with their time and the names of the monsters you were
  pointing at;
- where you left the window and the minimap button.

Gathering places are positions you stood at. They are in your saved file and, if you use the companion app, on your
guild's site, where the guild's ledger keeper can read them.

## The addon

Install it from CurseForge or Wago with any addon manager, or unzip the release into
`World of Warcraft/_forever_/Interface/AddOns/`.

| Command | What it does |
|---|---|
| `/ledger` | Status: recipes, crafts, disenchants, gathers and corpses recorded |
| `/ledger show` | Opens or closes the window |
| `/ledger minimap` | Hides the minimap button or brings it back |
| `/ledger token` | Shows your upload token, to give to your guild's ledger keeper |

The window lists the last 50 things recorded (the monster or the vein, the items as links, the coin) and the counts
of this session and in total. The minimap button opens it with a left click and shows your token with a right click;
its tooltip gives the counts. The window can also be opened from the game's AddOns options.

At every login the addon says in the chat which version is running; a copy taken from this repository instead of
a release says `dev`.

**The addon sends nothing**, in game or out of it: no addon messages, no chat, nothing to other players. It writes
its record and the per-character file to its saved files when you log out, as every addon does. Without the
companion app the record never leaves your computer.

The addon is free, its code is readable, and it shows no advertising, as Blizzard's add-on policy requires.

## The companion app

The game cannot send data to a website; an addon can only write a file when you log out. The companion app watches
that file and uploads it.

1. Download `RookieLedgerSync.exe` (Windows) or `rookieledger-sync-linux-amd64` (Linux) from the
   [latest release](../../releases/latest).
2. Windows: double-click it. It has no window: it copies itself to `%LocalAppData%\RookieLedgerSync`, sets that copy
   to start with your session and runs in the background, so the downloaded file can be deleted. To update, download
   the new version and double-click it.
   Linux: `chmod +x rookieledger-sync-linux-amd64 && ./rookieledger-sync-linux-amd64 --install` (a systemd user unit).
3. In game, type `/ledger token` and give the token to your guild's ledger keeper. Uploads start once the keeper has
   registered it.

**Windows warning.** The app is not code-signed, so Windows shows "Windows protected your PC" on first run: choose
*More info*, then *Run anyway*. The binaries are built by GitHub Actions from the tagged source of this repository;
`SHA256SUMS.txt` in each release lets you check your download. Windows 11 machines with Smart App Control switched on
block unsigned programs with no bypass.

| Option | What it does |
|---|---|
| `--status` | Shows the saved files found, their tokens and why the site refused a file, then exits |
| `--once` | One pass, then exits |
| `--install` / `--uninstall` | Adds or removes the start with your session (Windows: `--uninstall` also stops and removes the installed copy) |
| `--wow-dir DIR` | The `World of Warcraft` folder, when it is not found by itself (remembered) |
| `--url URL` | Another guild's upload address (remembered; `--url default` goes back) |

### What the app sends, and where

- It contacts one address only: the upload site (by default the site of the guild this addon was written for).
- Until your token is registered, it asks "is this token known?" at most once every 30 minutes and sends nothing else.
- Once registered, it sends the addon's account-wide saved file
  (`WTF/Account/<account>/SavedVariables/RookieLedger.lua`) when its content has changed, with the token. That file
  holds the record described above, gathering places included. The per-character file of the same name, one folder
  deeper, is not read.
- It reads no other file, sends no telemetry and does not update itself.

The token is the only credential. Give it to the ledger keeper and to nobody else; to stop uploading, run
`--uninstall`, or ask the keeper to revoke the token. The app's log shows only the first six digits of a token.

## Running a site for your own guild

`server/` is the whole upload service: Python 3.12 standard library, one SQLite file.

```sh
python3 -I server/ledger_ingest.py --port 8787 --db data/ledger.sqlite   # behind a TLS reverse proxy
python3 -I server/ledger_admin.py add <token> "<who>"                   # register a member's token
python3 -I server/ledger_admin.py list | revoke <token or who> | unbind <token or who> | summary | purge
```

A site running an older `server/` keeps accepting uploads from a newer addon: what it does not know of a record
(quest items, before v0.4.0) is left out, not refused. Update `server/` to keep it.

An unknown token is refused before the request body is read. A token is tied to the record id of its first upload,
so a member cannot upload under another member's id; `unbind` lifts the tie for a member whose saved file was lost.
Members point the companion app at your site once: `--url https://<your site>/api/ledger/v1`.

A database that received uploads from versions with guild sync (before v0.2.0) still holds the copies of other
members' records those versions sent along. Nothing reads them; `purge` deletes them. Copy the SQLite file first:
a purge cannot be undone.

## Development

```sh
python3 -I -m unittest discover -s tests -v    # addon (under lua5.1, against a stub of the WoW API) and server
cd companion && go test ./...                  # CI runs these on Linux and on Windows
```

The minimap button uses LibStub, CallbackHandler, LibDataBroker and LibDBIcon. They are not in the repository: the
packager fetches them into the zip (`externals` in `.pkgmeta`). A copy of `addon/RookieLedger` taken from the
repository has no button unless those four folders are put in `addon/RookieLedger/Libs/`, which git ignores;
everything else works without them.

[docs/client-behaviour.md](docs/client-behaviour.md) lists what the Forever client was seen to tell an addon about
kills, corpses and loot windows, with the number of cases behind each statement. Read it before changing what the
addon takes a loot window for.

A change to the record shape goes into `addon/RookieLedger/Record.lua`, `server/ledger_common.py` (`check_record`)
and both tests together.

Releases: push a tag such as `v0.2.0`. The workflow runs the tests above on the tagged commit, builds the companion
binaries and checks that `CHANGELOG.md` starts with `# RookieLedger v0.2.0`; it publishes nothing if one of these
fails. It then packages the addon with the [BigWigs packager](https://github.com/BigWigsMods/packager), uploads it
to CurseForge and Wago when their tokens are set as repository secrets, and attaches the binaries to the GitHub
release. Update `CHANGELOG.md` first: it is the release text. A tag with a suffix, such as `v0.2.1-beta1`, is
checked against the heading of its version, `# RookieLedger v0.2.1`.

## Licence

MIT. World of Warcraft is a trademark of Blizzard Entertainment; this project is not affiliated with Blizzard.
