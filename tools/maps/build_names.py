#!/usr/bin/env python3
"""Writes the names the map page shows for the game's ids, from the game's own tables: never from what members upload.

  python3 tools/maps/build_names.py <cache folder> <output folder> [--install <World of Warcraft folder>]
                                    [--api <address of the read API>]

names.json: {"items": {id: [name, quality]}, "creatures": {id: name}}. Items come from the client's tables. Those
hold no names of monsters, veins or herbs: the server tells them to the client as they are met, and the client
keeps what it was told in a cache file of the install. With --install the monsters' names are read from that file,
so they are the names of the monsters that install's player has met, in its language; the page shows any other
monster by its number, and names a vein or a herb after what it gives.

With --api as well, the monsters the site knows are compared with the names in hand. For those without a name a
small addon (tools/maps/asker) is written into the install with their list: at the next start of the game it has the
client ask the server for these names, which land in the same cache file. Leave the game, run this again, and they
are in names.json. Once every monster has a name the addon is taken out of the install.
"""
import argparse, json, shutil, struct, sys, urllib.request
from pathlib import Path
sys.path.insert(0, str(Path(__file__).absolute().parent))
from gamedata import AGENT, GameData


ASKER = Path(__file__).absolute().parent / "asker"   # the addon that asks the game for names, without its list
ASKER_NAME = "RookieLedgerNames"
NAME_AT = 15        # bytes into a record of the creature cache: where the name starts, after the lengths of its texts


def creatures(install, locale, product="_forever_"):
    """{id: name} from the client's cache of the creatures it has met (Cache/WDB/<locale>/creaturecache.wdb): a
    header of 24 bytes, then per creature its id, the size of what follows, and that, the name first among its
    texts and ended by a zero. A record that does not read as a name is left out."""
    path = Path(install) / product / "Cache" / "WDB" / locale / "creaturecache.wdb"
    data = path.read_bytes()
    if data[:4] != b"BOMW":
        raise ValueError(f"{path} is not a creature cache")
    names, at = {}, 24
    while at + 8 <= len(data):
        creature, size = struct.unpack_from("<II", data, at)
        record = data[at + 8:at + 8 + size]
        at += 8 + size
        if not creature or len(record) <= NAME_AT:
            continue
        raw = record[NAME_AT:].split(b"\0", 1)[0]
        try:
            name = raw.decode("utf-8")
        except UnicodeDecodeError:
            continue
        if 1 < len(name) <= 100 and name.isprintable() and name == name.strip():
            names[creature] = name
    return names


def looted(api):
    """The ids of the monsters the read API at `api` (https://<name>/v1) knows, all its pages."""
    ids, cursor = [], None
    while True:
        url = f"{api.rstrip('/')}/creatures?limit=1000" + (f"&cursor={cursor}" if cursor else "")
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": AGENT}), timeout=60) as answer:
            page = json.load(answer)
        ids += [int(row["id"]) for row in page["data"]]
        cursor = page.get("next_cursor")
        if not cursor:
            return sorted(set(ids))


def set_asker(install, ids, product="_forever_"):
    """Writes the addon that asks the game for the names of `ids` into the install, or takes it out when there is
    none to ask for. Returns its folder."""
    folder = Path(install) / product / "Interface" / "AddOns" / ASKER_NAME
    if not ids:
        if (folder / f"{ASKER_NAME}.toc").exists():   # ours: no other folder is ever removed
            shutil.rmtree(folder)
        return folder
    folder.mkdir(parents=True, exist_ok=True)
    for source in ASKER.iterdir():
        shutil.copyfile(source, folder / source.name)
    numbers = ", ".join(str(int(i)) for i in ids)
    (folder / "Ids.lua").write_text(f"-- Written by tools/maps/build_names.py: the monsters without a name.\n"
                                    f"RookieLedgerNamesIds = {{ {numbers} }}\n", encoding="utf-8")
    return folder


def main():
    ap = argparse.ArgumentParser(description="Write the names the map page shows")
    ap.add_argument("cache", type=Path)
    ap.add_argument("out", type=Path)
    ap.add_argument("--install", type=Path, help="the World of Warcraft folder: the names of the monsters its "
                                                 "player has met are read from its cache")
    ap.add_argument("--api", help="the read API (https://<name>/v1): its monsters without a name are listed and, "
                                  "with --install, an addon is written into the game that asks it for them")
    args = ap.parse_args()
    data = GameData(args.cache)
    # The game empties its cache at an update: the names read at earlier builds are kept beside the tables, so that
    # a monster once named stays named.
    kept = args.cache / f"creatures.{data.locale}.json"
    met = {int(k): v for k, v in json.loads(kept.read_text(encoding="utf-8")).items()} if kept.exists() else {}
    if args.install:
        met.update(creatures(args.install, data.locale))
        kept.write_text(json.dumps(dict(sorted(met.items())), ensure_ascii=False), encoding="utf-8")
    items = {int(r["ID"]): [r["Display_lang"], int(r["OverallQualityID"])]
             for r in data.table("ItemSparse") if r["Display_lang"]}
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "names.json").write_text(
        json.dumps({"build": data.build, "locale": data.locale, "items": dict(sorted(items.items())),
                    "creatures": dict(sorted(met.items()))}, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"{len(items)} item names, {len(met)} monster names", file=sys.stderr)
    if args.api:
        nameless = [i for i in looted(args.api) if i not in met]
        print(f"{len(nameless)} monsters of the site have no name" + (": " + " ".join(map(str, nameless)) if nameless
                                                                       else ""), file=sys.stderr)
        if args.install:
            folder = set_asker(args.install, nameless)
            if nameless:
                print(f"{folder} asks the game for them: start the game, enter the world with a character, wait "
                      f"for its line in the chat, leave the game, then run this again", file=sys.stderr)


if __name__ == "__main__":
    main()
