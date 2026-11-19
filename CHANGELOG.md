# RookieLedger v0.6.0

- New: the addon notes where you loot each kind of monster, as it already does for veins and herbs: the map and
  your position on it, to half a hundredth of the map. Nothing is noted where the game gives no position, as in a
  dungeon. Monsters looted before this version keep their counts and have no place.
- These places are positions you stood at. They go to your guild's site with the rest of the record.
- New in the record: when it began and how many seconds of play its changes took. A site that takes uploads from
  anyone holds a new record against these two numbers. A record begun with an older version has neither.
- A right click on the minimap button now opens the addon's options, no longer your token: the guild site this
  addon was written for takes uploads without one. `/ledger token` still shows it, for a site that asks.
- The companion app uploads to the guild site's new address. An app of an earlier version no longer reaches it:
  install this one.
- For who runs a guild site: the upload service now answers under `/v1/ledger/` (it was `/api/ledger/v1/`); members
  give the app `--url https://<your site>/v1/ledger`.
- For who runs a guild site: update `server/` to keep these places; an older site still accepts the uploads and
  leaves them out. `server/ledger_api.py` is new: a read-only API that gives out what the records say together
  (drop rates, yields, places, recipe colours) to a map page or any other program. See the README.
- For who runs a guild site: `ledger_ingest.py --registration open` takes uploads without a token registered by
  hand. It is off unless asked for. A token that registers itself is on probation for 48 hours and is held when
  its record was made faster than play allows; `ledger_admin.py digest` and `approve` are how you follow that. The
  README says what an open site gives up.
