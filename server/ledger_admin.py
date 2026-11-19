#!/usr/bin/env python3
"""Tokens and contents of the RookieLedger database (data/ledger.sqlite, see server/ledger_common.py).

  python3 -I server/ledger_admin.py add <token> "<who>"    register the token a member read off /ledger token
  python3 -I server/ledger_admin.py revoke <token | who | record id>   stop accepting it; its uploads no longer
                                                           count. On a site with open registration it is also the
                                                           way to shut a token out: it cannot register again
  python3 -I server/ledger_admin.py unbind <token | who>   let it upload a new record id (a member's saved file was lost)
  python3 -I server/ledger_admin.py list                   registered tokens and when each last uploaded
  python3 -I server/ledger_admin.py digest [hours]         on a site with open registration: the tokens that
                                                           registered themselves in the last hours (24) and those
                                                           held, with how much each recorded in how much play
  python3 -I server/ledger_admin.py approve <who | record id>   believe a token that registered itself: its record
                                                           counts at once, held or not
  python3 -I server/ledger_admin.py purge                  delete the copies of other members' records that versions
                                                           with guild sync uploaded; nothing reads them
  python3 -I server/ledger_admin.py summary                what the records say: thresholds, skill-ups, disenchants,
                                                           gathering yields and places, corpses looted per creature,
                                                           quest items
  python3 -I server/ledger_admin.py api-key add "<program>"     make a key of the read API for one program; it is
                                                                shown once
  python3 -I server/ledger_admin.py api-key revoke "<program>"  stop accepting that program's keys
  python3 -I server/ledger_admin.py api-key list                the programs that have a key

The upload endpoint notices a new or revoked token within 15 seconds, the read API a key; nothing needs restarting.
A key only matters while the read API runs with `--auth key`; without it the API answers everyone.
"""
import argparse, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).absolute().parent))
import ledger_common as lc

COLOURS = ("orange", "yellow", "green", "grey")
TOP_CREATURES = 20   # the summary lists the most looted ones; lc.drop_rates has them all


def summary(con, out=sys.stdout):
    records = lc.current_records(con)
    print(f"{len(records)} records", file=out)
    thresholds = lc.colour_thresholds(records)
    rates = lc.skill_up_rates(records)
    print(f"\nrecipe colours ({len(thresholds)} recipes): skill at which each colour starts, as (last seen before, first seen)",
          file=out)
    for recipe in sorted(thresholds, key=lambda r: (thresholds[r]["profession"], r)):
        t = thresholds[recipe]
        seen = " ".join(f"{COLOURS[c]} {r[0]}-{r[1]}" for c, r in enumerate(t["ranges"]) if r)
        steps = " ".join(f"{name}>{t[name][0]},<={t[name][1]}" for name in COLOURS[1:] if t[name])
        print(f"  profession {t['profession']} recipe {recipe}: {seen}{'  ' + steps if steps else ''}"
              f"{'  CONFLICT' if t['conflict'] else ''}", file=out)
    print(f"\nskill-ups per craft ({len(rates)} recipe colours)", file=out)
    for (recipe, colour), (made, ups) in sorted(rates.items()):
        print(f"  recipe {recipe} {COLOURS[colour]}: {ups}/{made} = {ups / made:.0%}", file=out)
    yields = lc.disenchant_yields(records)
    print(f"\ndisenchants ({len(yields)} quality, class and item level groups)", file=out)
    for (quality, klass, level), y in sorted(yields.items()):
        parts = ", ".join(f"item {m}: {avg:.2f} each, in {share:.0%}" for m, (avg, share) in sorted(y["materials"].items()))
        print(f"  quality {quality} {'weapon' if klass == 2 else 'armor'} item level {level}, {y['n']} disenchants: {parts}",
              file=out)
    gathered = lc.gather_yields(records)
    print(f"\ngathering ({len(gathered)} kinds of vein and herb)", file=out)
    for node, y in sorted(gathered.items()):
        parts = ", ".join(f"item {m}: {avg:.2f} each, in {share:.0%}" for m, (avg, share) in sorted(y["materials"].items()))
        print(f"  {'vein' if y['kind'] == 1 else 'herb'} {node}, {y['n']} gathers at {len(y['places'])} places: {parts}",
              file=out)
    drops = lc.drop_rates(records)
    print(f"\nmonster loot ({len(drops)} kinds of creature, {sum(d['n'] for d in drops.values())} corpses)", file=out)
    for creature, d in sorted(drops.items(), key=lambda kv: -kv[1]["n"])[:TOP_CREATURES]:
        coin = "coin unknown" if d["coin"] is None else f"{d['coin']:.0f} copper each"
        print(f"  creature {creature}, {d['n']} corpses, {coin}, {len(d['items'])} different items", file=out)
    quest_items = lc.quest_item_rates(records)
    print(f"\nquest items ({len(quest_items)} creature and item pairs): of the corpses looted while the quest wanted the item",
          file=out)
    for (creature, item), r in sorted(quest_items.items()):
        rate = "no corpse counted yet" if r["rate"] is None else f"{r['k']}/{r['n']} = {r['rate']:.0%}"
        print(f"  creature {creature} item {item} (quest {r['quest']}): {rate}", file=out)


def main():
    ap = argparse.ArgumentParser(description="Tokens and contents of the RookieLedger database")
    ap.add_argument("--db", type=Path, default=lc.DB_PATH)
    sub = ap.add_subparsers(dest="command", required=True)
    add = sub.add_parser("add")
    add.add_argument("token")
    add.add_argument("label")
    sub.add_parser("revoke").add_argument("token_or_label")
    sub.add_parser("unbind").add_argument("token_or_label")
    sub.add_parser("approve").add_argument("label_or_origin")
    sub.add_parser("digest").add_argument("hours", nargs="?", type=float, default=24)
    sub.add_parser("list")
    sub.add_parser("purge")
    sub.add_parser("summary")
    key = sub.add_parser("api-key")
    key.add_argument("action", choices=("add", "revoke", "list"))
    key.add_argument("label", nargs="?")
    args = ap.parse_args()
    con = lc.connect(args.db)
    if args.command == "api-key":
        if args.action == "list":
            for label, added, revoked in con.execute("SELECT label, added_at, revoked_at FROM api_keys ORDER BY added_at"):
                print(f"{label}: added {added}" + (f", revoked {revoked}" if revoked else ""))
        elif not args.label:
            sys.exit("name the program the key is for")
        elif args.action == "add":
            print(lc.add_api_key(con, args.label))
            print(f"this is the only time the key of {args.label} is shown", file=sys.stderr)
        else:
            print(f"revoked {lc.revoke_api_key(con, args.label)} key(s)")
    elif args.command == "add":
        try:
            lc.add_token(con, args.token.strip().lower(), args.label)
        except lc.LedgerError as error:
            sys.exit(str(error))
        print(f"registered {args.label}")
    elif args.command == "revoke":
        print(f"revoked {lc.revoke_token(con, args.token_or_label)} token(s)")
    elif args.command == "approve":
        print(f"approved {lc.approve_token(con, args.label_or_origin)} token(s)")
    elif args.command == "digest":
        print("\n".join(lc.digest(con, args.hours)) or "no token registered itself and none is held")
    elif args.command == "unbind":
        print(f"unbound {lc.unbind_token(con, args.token_or_label)} token(s)")
    elif args.command == "purge":
        print(f"deleted {lc.purge_relayed(con)} relayed record(s)")
    elif args.command == "list":
        for label, added, revoked, last, origin in con.execute(
                "SELECT label, added_at, COALESCE(revoked_at, 'held: ' || held), last_upload, origin "
                "FROM ledger_tokens ORDER BY added_at"):
            state = (revoked if revoked.startswith("held") else f"revoked {revoked}") if revoked else f"last upload {last or 'never'}"
            print(f"{label}: added {added}, {state}, record {origin or '-'}")
    else:
        summary(con)


if __name__ == "__main__":
    main()
