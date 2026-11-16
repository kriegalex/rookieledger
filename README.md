# RookieLedger

A World of Warcraft: Forever addon that records what the game shows about your professions, shares it with your
guild, and (optionally) uploads it to a guild site through a small companion app.

It answers questions that guides get wrong on Forever:

- at which skill does a recipe turn yellow, green and grey;
- how often does a yellow or green recipe really give a skill point;
- what does disenchanting an item of a given quality and item level really give;
- what does a vein or a herb really give, and where are they found.

## What is recorded

Only numbers the game client shows you about your own professions:

- the colour of each recipe at your current skill, read while your profession window is open;
- per recipe and colour, how many crafts you made and how many gave a skill point;
- per disenchanted item: its quality, class and item level, and the materials received;
- per kind of vein or herb you gathered: how often, the materials received, and the places (map and position on it)
  where you gathered it.

No character name, account name, realm, guild name, chat, gold or inventory is recorded. A record is named by a random
8-digit id made on first login.

**Gathering places are positions you stood at, so they are shared a day late.** What a vein or herb gave is sent to
the guild within minutes; where you gathered it is held back for 24 hours after your last gather at that place, and
is sent without a time. Guild sync therefore never says where you are or just were. With `/ledger sync off` the
places stay in your own saved file and, if you use the companion app, on the guild site.

A record only grows: a skill range widens, a count goes up. Nothing in it is ever lowered or removed.

## The addon

Install it from CurseForge or Wago with any addon manager, or unzip the release into
`World of Warcraft/_forever_/Interface/AddOns/`.

| Command | What it does |
|---|---|
| `/ledger` | Status: recipes, crafts, disenchants and gathers recorded, guild records received |
| `/ledger token` | Shows your upload token, to give to your guild's ledger keeper |
| `/ledger sync on` or `off` | Turns guild sync on or off |

**Guild sync.** Guild members who run the addon exchange their records on the guild addon channel, which no player
sees. After a change only the changed lines are sent, the queue stays well under the game's message limit and waits
during encounters and battlegrounds. Records received in one guild are not passed on in another.
`/ledger sync off` stops all sending and receiving.

Guild sync cannot prove who wrote a record: a guild member could send a made-up one under another member's id. The
author's addon notices and sends the real one again, and on the site an author's own upload always wins over a copy
relayed by someone else.

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
- Once registered, it sends the addon's saved file (`RookieLedger.lua`) when its content has changed, with the token.
  That file holds the records described above, gathering places included, yours and the ones received from guild
  members.
- It reads no other file, sends no telemetry and does not update itself.

The token is the only credential. Give it to the ledger keeper and to nobody else; to stop uploading, run
`--uninstall`, or ask the keeper to revoke the token. The app's log shows only the first six digits of a token.

## Running a site for your own guild

`server/` is the whole upload service: Python 3.12 standard library, one SQLite file.

```sh
python3 -I server/ledger_ingest.py --port 8787 --db data/ledger.sqlite   # behind a TLS reverse proxy
python3 -I server/ledger_admin.py add <token> "<who>"                   # register a member's token
python3 -I server/ledger_admin.py list | revoke <token or who> | unbind <token or who> | summary
```

An unknown token is refused before the request body is read. A token is tied to the record id of its first upload,
so a member cannot upload under another member's id; `unbind` lifts the tie for a member whose saved file was lost.
Members point the companion app at your site once: `--url https://<your site>/api/ledger/v1`.

## Development

```sh
python3 -I -m unittest discover -s tests -v    # addon (under lua5.1, against a stub of the WoW API) and server
cd companion && go test ./...                  # CI runs these on Linux and on Windows
```

A change to the record shape goes into `addon/RookieLedger/Record.lua`, `server/ledger_common.py` (`check_record`)
and both tests together.

Releases: push a tag such as `v0.2.0`. The workflow packages the addon with the
[BigWigs packager](https://github.com/BigWigsMods/packager), uploads it to CurseForge and Wago when their tokens are
set as repository secrets, and attaches the companion binaries to the GitHub release. Update `CHANGELOG.md` first: it
is the release text.

## Licence

MIT. World of Warcraft is a trademark of Blizzard Entertainment; this project is not affiliated with Blizzard.
