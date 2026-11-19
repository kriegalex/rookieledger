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
- per kind of monster you looted alone: how many corpses, their coin, every item they held (quest items left out),
  and the places (map and position on it, to half a hundredth of the map) where you looted them;
- per quest item a kind of monster gave you: the quest and the objective that asked for it, how many corpses of that
  monster you looted while the quest still wanted the item, and how many of them held it.

A quest item only drops for who has the quest, which is why it is counted apart: against the corpses looted while
the quest wanted it, not against all of them. The addon learns which quest that is from your quest log, the first
time the item shows in a corpse; that first corpse is not counted, so that the drop that made the item known does
not raise its rate. Of your quests, the record holds only the number of a quest that asked for such an item.

No character name, account name, realm, guild name, chat, gold total or inventory is recorded. Of time, the record
holds three numbers: when it began, when it last changed, and how many seconds of play its changes took. A site
that takes uploads from anyone uses them to tell a record that was played from one that was made up. A record is named by a random 8-digit id made on first login. A record only
grows: a skill range widens, a count goes up.

Beside the record, the addon keeps one small file per character that never leaves your computer. The companion app
does not read it. It holds:

- the game's own names for the last 500 corpses it counted, so that a corpse opened again after a reload or a new
  login is not counted twice. Those names tell the realm and when each monster appeared, which is why they are kept
  out of the record;
- the last 50 things recorded as the window shows them, with their time and the names of the monsters you were
  pointing at;
- where you left the window and the minimap button, and your settings for the monster tooltip.

Gathering and looting places are positions you stood at. They are in your saved file and, if you use the companion
app, on your guild's site. A site that runs the read API gives them out added up over all members, to whoever may read that API,
with no word of who stood where; while few members upload, a total is close to what one of them did.

## The addon

Install it from CurseForge or Wago with any addon manager, or unzip the release into
`World of Warcraft/_forever_/Interface/AddOns/`.

| Command | What it does |
|---|---|
| `/ledger` | Status: recipes, crafts, disenchants, gathers and corpses recorded |
| `/ledger show` | Opens or closes the window |
| `/ledger minimap` | Hides the minimap button or brings it back |
| `/ledger tooltip` | Switches the loot lines in monster tooltips off or on |
| `/ledger token` | Shows your upload token, for a guild site that registers tokens by hand |

The window lists the last 50 things recorded (the monster or the vein, the items as links, the coin) and the counts
of this session and in total. The minimap button opens it with a left click and the addon's options with a right click;
its tooltip gives the counts. The window can also be opened from the game's AddOns options.

Pointing at a monster shows, under its tooltip, what that kind of monster gave you so far: how many you looted, each
item with how often it was there, the quest items against the corpses looted while the quest wanted them, and the
coin on average. These are your own figures, the only ones the addon has: it receives nothing from the guild site.
Under ten corpses a rate reads "3/7", not as a percentage. In the AddOns options you can switch these lines off and
choose the quality from which items are shown (all of them, or from common, uncommon, rare or epic up).

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
3. Play. On a site open to all, such as the one this addon was written for, uploads start by themselves after your
   next game session. On a site that registers tokens by hand, type `/ledger token` in game and give the token to
   your guild's ledger keeper; uploads start once the keeper has registered it.

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

The token is the only credential: it is what ties your record to you. Give it to nobody, except to the ledger
keeper of a site that registers tokens by hand; to stop uploading, run `--uninstall`, or ask the keeper to revoke
the token. The app's log shows only the first six digits of a token.

## Running a site for your own guild

`server/` is the whole site: an upload service and a read API, Python 3.12 standard library, one SQLite file.

```sh
python3 -I server/ledger_ingest.py --port 8787 --db data/ledger.sqlite   # behind a TLS reverse proxy
python3 -I server/ledger_admin.py add <token> "<who>"                   # register a member's token
python3 -I server/ledger_admin.py list | revoke <token, who or record id> | unbind <token or who> | summary | purge
python3 -I server/ledger_admin.py digest [hours] | approve <who or record id>   # for a site with open registration
```

A site running an older `server/` keeps accepting uploads from a newer addon: what it does not know of a record
(quest items, before v0.4.0) is left out, not refused. Update `server/` to keep it.

An unknown token is refused before the request body is read. A token is tied to the record id of its first upload,
so a member cannot upload under another member's id; `unbind` lifts the tie for a member whose saved file was lost.

A site can instead take uploads from anyone who has the addon and the app, with no token to hand over:

```sh
python3 -I server/ledger_ingest.py --port 8787 --db data/ledger.sqlite --registration open   # or LEDGER_REGISTRATION=open
```

A token the site never saw then registers itself with its first upload that passes the checks, under the label
`self-<record id>`; the app needs no setting for it. The token remains the secret that ties a record to who made
it, and `revoke <record id>` shuts one out for good. What an open site gives up:

- it reads up to 1 MiB from a stranger before knowing them, at most 30 such uploads a minute, and lets 50 tokens
  register per day;
- it cannot know that a record was played. Nothing in the game signs what an addon writes, and a saved file is
  text anyone can edit. One invented record could bend every total the read API gives out.

So a token that registered itself is not taken at its word:

- **Probation.** Its record is kept at once but counts in nothing the site gives out for 48 hours.
- **Pace.** The record says when it began and how many seconds of play it took. At its first upload it is held to
  that account: at most 100 hours of play, no more than the time since it began, and at most 1200 things recorded
  (corpses, gathers, crafts, disenchants) per hour of play, plus 200. From the second upload on the site has its
  own clock: the play added cannot exceed the time between the two uploads. A record that fails is still kept,
  but its token is held: it counts for nothing until you approve it. The uploader is not told.
- **You decide.** `digest` lists the tokens that registered in the last 24 hours and every held one, with how much
  each recorded in how much play. `approve <record id>` believes one, at once and for good; `revoke <record id>`
  shuts one out. Run `digest` daily and send its output where you will read it.

```sh
python3 -I server/ledger_admin.py digest            # or: digest 72, for the last three days
python3 -I server/ledger_admin.py approve 0876cf1e
```

These numbers are wide on purpose and are constants at the top of `server/ledger_common.py`: narrow them once real
records show what play looks like. A record from an addon before v0.6.0 has no account of its time, so a token
that registers itself with one is held until approved. Tokens you registered by hand are believed as before.

Who knocks at the upload door without a member's token is answered with a notice of what the door is for, and
that generating data for it is not authorised. It keeps no one out; it tells an honest program, an AI agent
included, to stop.
Members point the companion app at your site once: `--url https://<your site>/v1/ledger`.

A database that received uploads from versions with guild sync (before v0.2.0) still holds the copies of other
members' records those versions sent along. Nothing reads them; `purge` deletes them. Copy the SQLite file first:
a purge cannot be undone.

### The read API

`server/ledger_api.py` gives out what the records say together, as JSON, for a map page, a market site or any other
program. It opens the database read-only and is a process of its own, so that reading cannot touch what uploads
write. Both can answer under one name: the upload service has everything below `/v1/ledger/`, the read API the
rest of `/v1`, and the reverse proxy sends each path to its process.

```sh
python3 -I server/ledger_api.py --port 8788 --db data/ledger.sqlite    # behind a TLS reverse proxy
curl http://localhost:8788/v1                                          # what it holds, and where
curl http://localhost:8788/v1/openapi.json                             # the contract, as OpenAPI 3.1
```

| Path | What it answers |
| --- | --- |
| `/v1/creatures`, `/v1/creatures/{id}`, `/v1/creatures/{id}/places` | per kind of monster: corpses, coin, what they held, quest items, and where it was looted |
| `/v1/items`, `/v1/items/{id}` | per item: the monsters, veins, herbs and disenchants that gave it |
| `/v1/nodes`, `/v1/nodes/{id}`, `/v1/nodes/{id}/places` | per kind of vein or herb: what it gave, and where it was gathered |
| `/v1/maps`, `/v1/maps/{id}`, `/v1/maps/{id}/node-places`, `/v1/maps/{id}/creature-places` | everything placed on one map: what a map page loads |
| `/v1/recipes`, `/v1/recipes/{id}` | the skill at which a recipe's colour turns, and skill points per craft |
| `/v1/disenchants` | what disenchanting gave, per quality, class and item level |

- It serves totals over all records. No record id, token or time of play is in any answer.
- A monster's place is where a player stood when looting it: where it died, which for a monster pulled away is
  not where it lives. Monsters looted before v0.6.0 of the addon have no place.
- Everything is named by the game's ids. The records hold no names, so the API has none to give.
- A collection answers `{"data": [...], "next_cursor": ...}`, 100 rows unless `limit` says otherwise (1000 at most);
  pass `next_cursor` back as `cursor` for the rest. Filters are query names (`/v1/creatures?item=2589`); a name the
  API does not know is refused, not ignored.
- Errors are problem documents (RFC 9457). Answers carry an `ETag` and may be cached for a minute; any origin may
  read them from a browser.
- Within `/v1` fields are only ever added. A change that would break a client gets a new prefix.
- New uploads show within 15 seconds.

It answers everyone unless started with `--auth key` (or with `LEDGER_API_AUTH=key` in its environment, which is the
switch for a deployment). Then every request needs `Authorization: Bearer <key>`:

```sh
python3 -I server/ledger_admin.py api-key add "map page"     # prints the key once; only its hash is kept
python3 -I server/ledger_admin.py api-key revoke "map page"
python3 -I server/ledger_admin.py api-key list
```

One key per program, so that a program can be counted, limited or shut out alone. A key that a web page carries can
be read by its visitors: it tells programs apart, it does not keep the data secret. `/healthz` and the OpenAPI
document stay open. The service limits no one's rate itself; do that in the reverse proxy.

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
and both tests together. What the read API serves is made in `server/ledger_api.py` from one table of routes, which
is also what its OpenAPI document is written from; `tests/test_api.py` holds every answer against that document.

Releases: push a tag such as `v0.2.0`. The workflow runs the tests above on the tagged commit, builds the companion
binaries and checks that `CHANGELOG.md` starts with `# RookieLedger v0.2.0`; it publishes nothing if one of these
fails. It then packages the addon with the [BigWigs packager](https://github.com/BigWigsMods/packager), uploads it
to CurseForge and Wago when their tokens are set as repository secrets, and attaches the binaries to the GitHub
release. Update `CHANGELOG.md` first: it is the release text. A tag with a suffix, such as `v0.2.1-beta1`, is
checked against the heading of its version, `# RookieLedger v0.2.1`.

## Licence

MIT. World of Warcraft is a trademark of Blizzard Entertainment; this project is not affiliated with Blizzard.
