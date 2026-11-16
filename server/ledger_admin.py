#!/usr/bin/env python3
"""Tokens and contents of the RookieLedger database (data/ledger.sqlite, see server/ledger_common.py).

  python3 -I server/ledger_admin.py add <token> "<who>"    register the token a member read off /ledger token
  python3 -I server/ledger_admin.py revoke <token | who>   stop accepting it; its uploads no longer count
  python3 -I server/ledger_admin.py list                   registered tokens and when each last uploaded
  python3 -I server/ledger_admin.py summary                what the records say: thresholds, skill-ups, disenchants

The upload endpoint notices a new or revoked token within 15 seconds; nothing needs restarting.
"""
import argparse, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).absolute().parent))
import ledger_common as lc

COLOURS = ("orange", "yellow", "green", "grey")


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


def main():
    ap = argparse.ArgumentParser(description="Tokens and contents of the RookieLedger database")
    ap.add_argument("--db", type=Path, default=lc.DB_PATH)
    sub = ap.add_subparsers(dest="command", required=True)
    add = sub.add_parser("add")
    add.add_argument("token")
    add.add_argument("label")
    sub.add_parser("revoke").add_argument("token_or_label")
    sub.add_parser("list")
    sub.add_parser("summary")
    args = ap.parse_args()
    con = lc.connect(args.db)
    if args.command == "add":
        try:
            lc.add_token(con, args.token.strip().lower(), args.label)
        except lc.LedgerError as error:
            sys.exit(str(error))
        print(f"registered {args.label}")
    elif args.command == "revoke":
        print(f"revoked {lc.revoke_token(con, args.token_or_label)} token(s)")
    elif args.command == "list":
        for label, added, revoked, last, origin in con.execute(
                "SELECT label, added_at, revoked_at, last_upload, origin FROM ledger_tokens ORDER BY added_at"):
            state = f"revoked {revoked}" if revoked else f"last upload {last or 'never'}"
            print(f"{label}: added {added}, {state}, record {origin or '-'}")
    else:
        summary(con)


if __name__ == "__main__":
    main()
