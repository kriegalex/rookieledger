#!/usr/bin/env python3
"""Read API of RookieLedger: what the uploaded records say together, as JSON, for a map page, a market site or any
other program. It only reads: the database is opened read-only and no request changes anything.

  python3 -I server/ledger_api.py --port 8788 [--db data/ledger.sqlite] [--prefix /v1] [--auth none|key]

  GET /v1                          what the service holds and where each collection is
  GET /v1/openapi.json             this API as an OpenAPI 3.1 document: the contract clients are written against
  GET /v1/creatures[/{id}]         per kind of monster: corpses, coin, what they held, quest items
  GET /v1/creatures/{id}/places    where that kind was looted
  GET /v1/items[/{id}]             per item: which monsters, veins, herbs and disenchants gave it
  GET /v1/nodes[/{id}]             per kind of vein or herb: gathers and what they gave
  GET /v1/nodes/{id}/places        where that kind was gathered
  GET /v1/maps[/{id}]              the maps that have places
  GET /v1/maps/{id}/node-places    every gathering place of one map
  GET /v1/maps/{id}/creature-places  every place of one map where a monster was looted
  GET /v1/places                   every place of every map in one compact document: what a map page loads
  GET /v1/recipes[/{id}]           per recipe: the skill at which its colour turns, skill points per craft
  GET /v1/disenchants              per quality, class and item level: what disenchanting gave
  GET /healthz                     200 while the process answers, with the version of the service

What a client can rely on:
- Totals over every record, never one member's: no record id, no token and no time of play leaves the database.
- A collection answers {"data": [...], "next_cursor": "..." or null}, sorted by id; pass the cursor back to go on.
  `limit` is 1 to MAX_LIMIT. A cursor stays valid when the data changes: it names the last row seen, not a position.
- A name the API does not know in the query is refused (400), so that a misspelt filter is not taken for none.
- An error is an RFC 9457 problem document (application/problem+json).
- Every answer has a weak ETag and `Cache-Control: public`; `If-None-Match` is answered 304. Answers are gzipped
  for who accepts it. Any origin may read (CORS): nothing here depends on who asks.
- With `--auth key` (or LEDGER_API_AUTH=key in the environment; off unless asked for) every request but /healthz
  and the OpenAPI document needs `Authorization: Bearer <key>`, a key made with `ledger_admin.py api-key add`.
  Another answer is 401. Answers are then `Cache-Control: private`. A key names a program so that it can be
  counted, limited or shut out; one that a web page carries is readable by its visitors and protects nothing.
- Within /v1 fields are added, never renamed or removed. A change that breaks a client gets a new prefix.
"""
import argparse, base64, bisect, gzip, hashlib, json, os, re, sqlite3, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qsl, urlsplit
sys.path.insert(0, str(Path(__file__).absolute().parent))
import ledger_common as lc

REFRESH = 15            # seconds between two looks at the database for new uploads
MAX_AGE = 60            # seconds a cache may answer in the service's place
DEFAULT_LIMIT = 100
MAX_LIMIT = 1000
MAX_CACHED = 512        # answers kept ready per state of the database
MAX_CACHED_BYTES = 32 * 2**20   # and their size, plain and gzipped: one query spelt many ways (limit=1000,
                                # limit=01000, %31000...) is many answers, each a page as large as a page can be
PLACES_WARN = 5 * 2**20         # gzipped size of /places past which the log says a map page should load less at once
AUTH_MODES = ("none", "key")
COLOURS = ("orange", "yellow", "green", "grey")
KINDS = {1: "mining", 2: "herbalism"}
ITEM_CLASSES = {2: "weapon", 4: "armor"}
QUALITIES = {2: "uncommon", 3: "rare", 4: "epic"}
TITLES = {400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed", 500: "Internal Server Error"}


class ApiError(Exception):
    def __init__(self, status, detail):
        super().__init__(detail)
        self.status, self.detail = status, detail


def ratio(part, whole):
    return round(part / whole, 4) if whole else None


def yielded(item, quantity, times, total):
    """One thing received: on `times` of the `total` occasions, `quantity` of it in all."""
    return {"item": item, "times": times, "quantity": quantity, "rate": ratio(times, total),
            "average_quantity": ratio(quantity, times)}


def _sum_pairs(into, pairs):
    for key, (quantity, times) in pairs.items():
        q, t = into.get(int(key), (0, 0))
        into[int(key)] = (q + quantity, t + times)


def _sum_places(into, places):
    for place, times in places.items():
        where = tuple(int(part) for part in place.split(":"))
        into[where] = into.get(where, 0) + times


def _by_map(places):
    """{map: its places, in the order of `places`}: a map page asks for one map at a time, page after page, and each
    page would otherwise be a pass over every place of every map."""
    out = {}
    for place in places:
        out.setdefault(place["map"], []).append(place)
    return out


class View:
    """Every document the API serves, built once per state of the database."""

    def __init__(self, records, updated_at=None):
        self.record_count, self.updated_at, self.cache, self.cached_bytes = len(records), updated_at, {}, 0
        # The one large answer, /places, is kept apart from the others and made by one request at a time: the cache
        # is emptied whenever it is full, and every map page asks for this.
        self.kept, self.making = None, threading.Lock()
        self.items, self.maps = {}, {}
        self._creatures(records)
        self._nodes(records)
        for m in self.maps.values():
            m["nodes"], m["creatures"] = sorted(m["nodes"]), sorted(m["creatures"])
        self._recipes(records)
        self._disenchants(records)
        for source in self.items.values():
            for rows in source.values():
                if isinstance(rows, list):
                    rows.sort(key=lambda row: [value for value in row.values() if isinstance(value, int)])

    def _item(self, item):
        return self.items.setdefault(item, {"id": item, "dropped_by": [], "quest_dropped_by": [], "gathered_from": [],
                                            "disenchanted_from": []})

    def _map(self, map_id):
        return self.maps.setdefault(map_id, {"id": map_id, "nodes": set(), "node_place_count": 0, "gathers": 0,
                                             "creatures": set(), "creature_place_count": 0, "corpses": 0})

    def _creatures(self, records):
        acc = {}
        blank = lambda: {"n": 0, "cn": 0, "c": 0, "i": {}, "q": {}, "p": {}}
        for rec in records.values():
            for creature, entry in rec.get("m", {}).items():
                a = acc.setdefault(int(creature), blank())
                a["n"], a["cn"], a["c"] = a["n"] + entry["n"], a["cn"] + entry["cn"], a["c"] + entry["c"]
                _sum_pairs(a["i"], entry["i"])
                _sum_places(a["p"], entry.get("p", {}))   # none in a record stored before places were kept
        for (creature, item), q in lc.quest_item_rates(records).items():
            acc.setdefault(creature, blank())["q"][item] = q
        self.creatures, self.creature_places = {}, []
        for creature, a in acc.items():
            for (map_id, x, y), times in a["p"].items():
                # "at" is the row's place in the order of a listing; it is not served.
                self.creature_places.append({"at": (map_id, creature, x, y), "creature": creature, "map": map_id,
                                             "x": x / 1000, "y": y / 1000, "corpses": times})
                m = self._map(map_id)
                m["creature_place_count"], m["corpses"] = m["creature_place_count"] + 1, m["corpses"] + times
                m["creatures"].add(creature)
            drops = [yielded(item, q, t, a["n"]) for item, (q, t) in sorted(a["i"].items())]
            quest_drops = [{"item": item, "quest": q["quest"], "chances": q["n"], "drops": q["k"],
                            "quantity": round(q["each"] * q["k"]) if q["k"] else 0, "rate": ratio(q["k"], q["n"])}
                           for item, q in sorted(a["q"].items())]
            self.creatures[creature] = {"id": creature, "corpses": a["n"], "coin_corpses": a["cn"],
                                        "coin_total": a["c"], "coin_average": ratio(a["c"], a["cn"]),
                                        "place_count": len(a["p"]), "maps": sorted({where[0] for where in a["p"]}),
                                        "drops": drops, "quest_drops": quest_drops}
            for drop in drops:
                self._item(drop["item"])["dropped_by"].append(
                    {"creature": creature, "corpses": a["n"], **{k: v for k, v in drop.items() if k != "item"}})
            for drop in quest_drops:
                self._item(drop["item"])["quest_dropped_by"].append(
                    {"creature": creature, **{k: v for k, v in drop.items() if k != "item"}})
        self.creature_places.sort(key=lambda place: place["at"])
        self.creature_places_by_map = _by_map(self.creature_places)

    def _nodes(self, records):
        acc = {}
        for rec in records.values():
            for node, entry in rec.get("g", {}).items():
                a = acc.setdefault(int(node), {"k": entry["k"], "n": 0, "m": {}, "p": {}})
                a["n"] += entry["n"]
                _sum_pairs(a["m"], entry["m"])
                _sum_places(a["p"], entry["p"])
        self.nodes, self.node_places = {}, []
        for node, a in acc.items():
            kind = KINDS[a["k"]]
            materials = [yielded(item, q, t, a["n"]) for item, (q, t) in sorted(a["m"].items())]
            self.nodes[node] = {"id": node, "kind": kind, "gathers": a["n"], "place_count": len(a["p"]),
                                "maps": sorted({where[0] for where in a["p"]}), "materials": materials}
            for material in materials:
                self._item(material["item"])["gathered_from"].append(
                    {"node": node, "kind": kind, "gathers": a["n"], **{k: v for k, v in material.items() if k != "item"}})
            for (map_id, x, y), times in a["p"].items():
                self.node_places.append({"at": (map_id, node, x, y), "node": node, "kind": kind, "map": map_id,
                                         "x": x / 1000, "y": y / 1000, "gathers": times})
                m = self._map(map_id)
                m["node_place_count"], m["gathers"] = m["node_place_count"] + 1, m["gathers"] + times
                m["nodes"].add(node)
        self.node_places.sort(key=lambda place: place["at"])
        self.node_places_by_map = _by_map(self.node_places)

    def _recipes(self, records):
        thresholds, rates = lc.colour_thresholds(records), lc.skill_up_rates(records)
        self.recipes = {}
        for recipe in set(thresholds) | {recipe for recipe, _ in rates}:
            t = thresholds.get(recipe)
            ranges = t["ranges"] if t else [None] * 4
            crafts = {}
            for colour, name in enumerate(COLOURS):
                made, ups = rates.get((recipe, colour), (0, 0))
                crafts[name] = {"crafts": made, "skill_ups": ups, "skill_ups_per_craft": ratio(ups, made)} if made else None
            self.recipes[recipe] = {
                "id": recipe, "profession": t["profession"] if t else None,
                "seen": {name: {"lowest": r[0], "highest": r[1]} if r else None for name, r in zip(COLOURS, ranges)},
                "turns": {name: {"after": t[name][0], "by": t[name][1]} if t and t[name] else None
                          for name in COLOURS[1:]},
                "conflict": bool(t and t["conflict"]), "crafts": crafts}

    def _disenchants(self, records):
        acc = {}
        for rec in records.values():
            for entry in rec.get("d", {}).values():
                a = acc.setdefault((entry["q"], entry["k"], entry["l"]), {"n": 0, "m": {}})
                a["n"] += entry["n"]
                _sum_pairs(a["m"], entry["m"])
        self.disenchants = []
        for (quality, item_class, level), a in sorted(acc.items()):
            head = {"quality": QUALITIES[quality], "item_class": ITEM_CLASSES[item_class], "item_level": level,
                    "disenchants": a["n"]}
            materials = [yielded(item, q, t, a["n"]) for item, (q, t) in sorted(a["m"].items())]
            self.disenchants.append({"at": (quality, item_class, level), **head, "materials": materials})
            for material in materials:
                self._item(material["item"])["disenchanted_from"].append(
                    {**head, **{k: v for k, v in material.items() if k != "item"}})


# Requests -----------------------------------------------------------------------------------------------------------

def _number(q, name, lo=1, hi=lc.MAX_ID):
    """The whole number given for `name`, None when it is not given, 400 when it is anything else."""
    if name not in q:
        return None
    text = q[name]
    if not (text.isascii() and text.isdigit() and len(text) <= 9 and lo <= int(text) <= hi):
        raise ApiError(400, f"{name} must be a whole number from {lo} to {hi}")
    return int(text)


def _choice(q, name, choices):
    if name in q and q[name] not in choices:
        raise ApiError(400, f"{name} must be one of: {', '.join(choices)}")
    return q.get(name)


def _page(rows, key, q):
    """One page of `rows`, which are sorted by `key`, after the row the cursor names."""
    limit = _number(q, "limit", 1, MAX_LIMIT) or DEFAULT_LIMIT
    start = 0
    if "cursor" in q:
        try:
            after = json.loads(base64.urlsafe_b64decode(q["cursor"].encode("ascii") + b"=="))
            if not (isinstance(after, list) and after and len(after) <= 4
                    and all(type(part) is int and 0 <= part <= 10**9 for part in after)):
                raise ValueError
        except (ValueError, UnicodeError):
            raise ApiError(400, "cursor is not one this API gave") from None
        start = bisect.bisect_right(rows, tuple(after), key=key)
    chunk = rows[start:start + limit]
    cursor = None
    if start + limit < len(rows):
        cursor = base64.urlsafe_b64encode(json.dumps(key(chunk[-1]), separators=(",", ":")).encode()).decode().rstrip("=")
    return {"data": [{k: v for k, v in row.items() if k != "at"} for row in chunk], "next_cursor": cursor}


def _by_id(table, rows=None):
    rows = [table[key] for key in sorted(table)] if rows is None else rows
    return rows, lambda row: (row["id"],)


def _one(table, key, what):
    if key not in table:
        raise ApiError(404, f"no {what} {key} in the records")
    return table[key]


def root(view, q, prefix):
    return {"name": "RookieLedger", "version": "v1", "records": view.record_count, "updated_at": view.updated_at,
            "counts": {"creatures": len(view.creatures), "items": len(view.items), "nodes": len(view.nodes),
                       "node_places": len(view.node_places), "creature_places": len(view.creature_places),
                       "maps": len(view.maps), "recipes": len(view.recipes),
                       "disenchants": len(view.disenchants)},
            "links": {name: f"{prefix}/{name}" for name in
                      ("creatures", "items", "nodes", "maps", "places", "recipes", "disenchants", "openapi.json")}}


def creatures(view, q):
    item, map_id = _number(q, "item"), _number(q, "map", 1, lc.MAX_MAP)
    rows, key = _by_id(view.creatures)
    if item is not None:
        rows = [row for row in rows if any(drop["item"] == item for drop in row["drops"] + row["quest_drops"])]
    return _page([row for row in rows if map_id is None or map_id in row["maps"]], key, q)


def nodes(view, q):
    kind, map_id = _choice(q, "kind", KINDS.values()), _number(q, "map", 1, lc.MAX_MAP)
    rows, key = _by_id(view.nodes)
    rows = [row for row in rows if kind in (None, row["kind"]) and (map_id is None or map_id in row["maps"])]
    return _page(rows, key, q)


def node_places(view, q, node=None, map_id=None):
    kind = _choice(q, "kind", KINDS.values())
    node = _number(q, "node") if node is None else node
    map_id = _number(q, "map", 1, lc.MAX_MAP) if map_id is None else map_id
    rows = view.node_places if map_id is None else view.node_places_by_map.get(map_id, [])
    rows = [row for row in rows if kind in (None, row["kind"]) and node in (None, row["node"])]
    return _page(rows, lambda row: row["at"], q)


def creature_places(view, q, creature=None, map_id=None):
    creature = _number(q, "creature") if creature is None else creature
    map_id = _number(q, "map", 1, lc.MAX_MAP) if map_id is None else map_id
    rows = view.creature_places if map_id is None else view.creature_places_by_map.get(map_id, [])
    rows = [row for row in rows if creature in (None, row["creature"])]
    return _page(rows, lambda row: row["at"], q)


def places(view, q):
    """Every place of every map, as few bytes as JSON allows: a map page asks for all of them at once, and one
    object per place would be several times the size and a request per thousand."""
    maps = {}
    blank = lambda: {"mining": {}, "herbalism": {}, "creatures": {}}
    for row in view.node_places:
        map_id, node, x, y = row["at"]
        maps.setdefault(map_id, blank())[row["kind"]].setdefault(str(node), []).extend((x, y, row["gathers"]))
    for row in view.creature_places:
        map_id, creature, x, y = row["at"]
        maps.setdefault(map_id, blank())["creatures"].setdefault(str(creature), []).extend((x, y, row["corpses"]))
    return {"maps": [{"id": map_id, **maps[map_id]} for map_id in sorted(maps)]}


def recipes(view, q):
    profession = _number(q, "profession")
    rows, key = _by_id(view.recipes)
    return _page([row for row in rows if profession in (None, row["profession"])], key, q)


def disenchants(view, q):
    quality, item_class = _choice(q, "quality", QUALITIES.values()), _choice(q, "item_class", ITEM_CLASSES.values())
    level = _number(q, "item_level", 1, 1000)
    rows = [row for row in view.disenchants if quality in (None, row["quality"])
            and item_class in (None, row["item_class"]) and level in (None, row["item_level"])]
    return _page(rows, lambda row: row["at"], q)


# One line per operation: path, the query names it takes, what answers, the schema of the answer (a collection when
# in a list), and what it is for. The router and the OpenAPI document are both made from this table.
PAGING = ("limit", "cursor")
ROUTES = [
    ("/creatures", ("item", "map") + PAGING, creatures, ["Creature"], "Monsters looted, with what they held"),
    ("/creatures/{creature}", (), lambda v, q, creature: _one(v.creatures, creature, "creature"), "Creature",
     "One kind of monster"),
    ("/creatures/{creature}/places", ("map",) + PAGING,
     lambda v, q, creature: creature_places(v, q, creature=_one(v.creatures, creature, "creature")["id"]),
     ["CreaturePlace"], "Where one kind of monster was looted"),
    ("/items", PAGING, lambda v, q: _page(*_by_id(v.items), q), ["Item"], "Items received, with where they came from"),
    ("/items/{item}", (), lambda v, q, item: _one(v.items, item, "item"), "Item", "Where one item came from"),
    ("/nodes", ("kind", "map") + PAGING, nodes, ["Node"], "Kinds of vein and herb gathered, with what they gave"),
    ("/nodes/{node}", (), lambda v, q, node: _one(v.nodes, node, "node"), "Node", "One kind of vein or herb"),
    ("/nodes/{node}/places", ("kind", "map") + PAGING,
     lambda v, q, node: node_places(v, q, node=_one(v.nodes, node, "node")["id"]), ["NodePlace"],
     "Where one kind of vein or herb was gathered"),
    ("/maps", PAGING, lambda v, q: _page(*_by_id(v.maps), q), ["Map"], "Maps that have places"),
    ("/maps/{map}", (), lambda v, q, map: _one(v.maps, map, "map"), "Map", "One map"),
    ("/maps/{map}/node-places", ("kind", "node") + PAGING,
     lambda v, q, map: node_places(v, q, map_id=_one(v.maps, map, "map")["id"]), ["NodePlace"],
     "Every gathering place of one map"),
    ("/maps/{map}/creature-places", ("creature",) + PAGING,
     lambda v, q, map: creature_places(v, q, map_id=_one(v.maps, map, "map")["id"]), ["CreaturePlace"],
     "Every place of one map where a monster was looted"),
    ("/places", (), places, "Places", "Every place of every map, in one compact document: what a map page loads"),
    ("/recipes", ("profession",) + PAGING, recipes, ["Recipe"], "Recipes, with the skill at which their colour turns"),
    ("/recipes/{recipe}", (), lambda v, q, recipe: _one(v.recipes, recipe, "recipe"), "Recipe", "One recipe"),
    ("/disenchants", ("quality", "item_class", "item_level") + PAGING, disenchants, ["Disenchant"],
     "What disenchanting gave, per quality, class and item level"),
]
_ROUTER = [(re.compile(re.sub(r"\{(\w+)\}", r"(?P<\1>[0-9]{1,9})", path)), names, handler)
           for path, names, handler, _schema, _summary in ROUTES]


def answer(view, path, query, prefix="/v1", auth=False):
    """The document for a path below the prefix and its query string, or ApiError."""
    q = {}
    for name, value in parse_qsl(query, keep_blank_values=True):
        if name in q:
            raise ApiError(400, f"{name} is given twice")
        q[name] = value
    if path in ("", "/"):
        names, call = (), lambda: root(view, q, prefix)
    elif path == "/openapi.json":
        names, call = (), lambda: openapi(prefix, auth)
    else:
        for pattern, names, handler in _ROUTER:
            m = pattern.fullmatch(path)
            if m:
                call = lambda: handler(view, q, **{name: int(value) for name, value in m.groupdict().items()})
                break
        else:
            raise ApiError(404, "no such resource; GET %s lists them" % prefix)
    unknown = sorted(set(q) - set(names))
    if unknown:
        raise ApiError(400, "unknown query name: %s%s" % (", ".join(unknown),
                                                          "; this resource takes: " + ", ".join(names) if names else ""))
    return call()


# The contract -------------------------------------------------------------------------------------------------------

def _obj(properties, description=None):
    out = {"type": "object", "additionalProperties": False, "required": list(properties), "properties": properties}
    return {**out, "description": description} if description else out


_INT, _COUNT = {"type": "integer", "minimum": 1}, {"type": "integer", "minimum": 0}
_RATE = {"type": ["number", "null"], "description": "null when there was no occasion to count against"}
_KIND = {"type": "string", "enum": list(KINDS.values())}
_YIELD = {"times": {**_COUNT, "description": "occasions on which it was received"},
          "quantity": {**_COUNT, "description": "how many were received in all"},
          "rate": {**_RATE, "description": "times / occasions; null without occasions"},
          "average_quantity": {**_RATE, "description": "quantity / times: how many at once when it was there"}}
_QUEST = {"quest": {**_INT, "description": "the quest most records name for it"},
          "chances": {**_COUNT, "description": "corpses looted while the quest still wanted the item"},
          "drops": {**_COUNT, "description": "those that held it"}, "quantity": _COUNT, "rate": _RATE}
_WHERE = {"map": {**_INT, "description": "the game's id of the map"},
          "x": {"type": "number", "minimum": 0, "maximum": 1, "description": "from the left edge of the map"},
          "y": {"type": "number", "minimum": 0, "maximum": 1, "description": "from the top edge of the map"}}
_FLAT = lambda id_of, count: {
    "type": "object", "additionalProperties": {"type": "array", "items": _COUNT},
    "description": f"per {id_of} (the game's id, as the key): its places on this map, three numbers each, one place "
                   f"after the other: x and y in thousandths of the map from its left and top edges, then {count}"}
_REF = lambda name: {"$ref": "#/components/schemas/" + name}
_NULLABLE = lambda schema: {"oneOf": [schema, {"type": "null"}]}
_DISENCHANT = {"quality": {"type": "string", "enum": list(QUALITIES.values())},
               "item_class": {"type": "string", "enum": list(ITEM_CLASSES.values())},
               "item_level": _INT, "disenchants": _COUNT}
SCHEMAS = {
    "Yield": _obj({"item": _INT, **_YIELD}, "One item received, counted against the occasions it could have been"),
    "QuestDrop": _obj({"item": _INT, **_QUEST}, "A quest item: counted only while a quest wanted it"),
    "Creature": _obj({"id": {**_INT, "description": "the game's id of the kind of monster"},
                      "corpses": {**_COUNT, "description": "corpses looted alone that held something"},
                      "coin_corpses": {**_COUNT, "description": "corpses whose coin is known"},
                      "coin_total": {**_COUNT, "description": "their coin, in copper"},
                      "coin_average": {**_RATE, "description": "copper per corpse whose coin is known"},
                      "place_count": _COUNT, "maps": {"type": "array", "items": _INT},
                      "drops": {"type": "array", "items": _REF("Yield")},
                      "quest_drops": {"type": "array", "items": _REF("QuestDrop")}}),
    "Item": _obj({"id": _INT,
                  "dropped_by": {"type": "array", "items": _obj({"creature": _INT, "corpses": _COUNT, **_YIELD})},
                  "quest_dropped_by": {"type": "array", "items": _obj({"creature": _INT, **_QUEST})},
                  "gathered_from": {"type": "array", "items": _obj({"node": _INT, "kind": _KIND, "gathers": _COUNT, **_YIELD})},
                  "disenchanted_from": {"type": "array", "items": _obj({**_DISENCHANT, **_YIELD})}}),
    "Node": _obj({"id": {**_INT, "description": "the game's id of the kind of vein or herb"}, "kind": _KIND,
                  "gathers": _COUNT, "place_count": _COUNT, "maps": {"type": "array", "items": _INT},
                  "materials": {"type": "array", "items": _REF("Yield")}}),
    "NodePlace": _obj({"node": _INT, "kind": _KIND, **_WHERE, "gathers": _COUNT},
                      "Where a player stood when gathering; two a step apart are two places"),
    "CreaturePlace": _obj({"creature": _INT, **_WHERE, "corpses": {**_COUNT, "description": "corpses looted there"}},
                          "A cell of the map, half a hundredth of it wide, in which a player stood when looting "
                          "that kind of monster: where it died, which is not always where it lives"),
    "Map": _obj({"id": {**_INT, "description": "the game's id of the map"},
                 "nodes": {"type": "array", "items": _INT}, "node_place_count": _COUNT, "gathers": _COUNT,
                 "creatures": {"type": "array", "items": _INT}, "creature_place_count": _COUNT,
                 "corpses": {**_COUNT, "description": "corpses looted on this map whose place is known"}}),
    "Places": _obj({"maps": {"type": "array", "items": _obj({
        "id": {**_INT, "description": "the game's id of the map"},
        "mining": _FLAT("kind of vein", "the gathers there"), "herbalism": _FLAT("kind of herb", "the gathers there"),
        "creatures": _FLAT("kind of monster", "the corpses looted there")})}},
        "The places of NodePlace and CreaturePlace, all of them, written short"),
    "Recipe": _obj({
        "id": {**_INT, "description": "the game's id of the recipe's spell"},
        "profession": _NULLABLE({**_INT, "description": "the game's id of the profession; null when only crafts are known"}),
        "seen": _obj({name: _NULLABLE(_obj({"lowest": _INT, "highest": _INT})) for name in COLOURS},
                     "the skill range in which the recipe was seen in each colour"),
        "turns": _obj({name: _NULLABLE(_obj({"after": _INT, "by": _INT})) for name in COLOURS[1:]},
                      "the colour is reached above `after` and at `by` at the latest; null while unknown"),
        "conflict": {"type": "boolean", "description": "ranges of two colours overlap: a wrong reading or a moved threshold"},
        "crafts": _obj({name: _NULLABLE(_obj({"crafts": _COUNT, "skill_ups": _COUNT, "skill_ups_per_craft": _RATE}))
                        for name in COLOURS})}),
    "Disenchant": _obj({**_DISENCHANT, "materials": {"type": "array", "items": _REF("Yield")}}),
    "Root": _obj({"name": {"type": "string"}, "version": {"type": "string"},
                  "records": {**_COUNT, "description": "how many members' records the totals are made of"},
                  "updated_at": {"type": ["string", "null"], "format": "date-time"},
                  "counts": {"type": "object", "additionalProperties": _COUNT},
                  "links": {"type": "object", "additionalProperties": {"type": "string"}}}),
    "Problem": {"type": "object", "required": ["type", "title", "status", "detail"], "description": "RFC 9457",
                "properties": {"type": {"type": "string"}, "title": {"type": "string"},
                               "status": {"type": "integer"}, "detail": {"type": "string"}}},
}
PARAMETERS = {
    "limit": ({"type": "integer", "minimum": 1, "maximum": MAX_LIMIT, "default": DEFAULT_LIMIT}, "rows per page"),
    "cursor": ({"type": "string"}, "the next_cursor of the page before"),
    "item": (_INT, "only what gave this item"), "kind": (_KIND, "only veins or only herbs"),
    "map": (_INT, "only what has a place on this map"), "node": (_INT, "only this kind of vein or herb"),
    "creature": (_INT, "only this kind of monster"),
    "profession": (_INT, "only recipes of this profession"),
    "quality": (_DISENCHANT["quality"], "only items of this quality"),
    "item_class": (_DISENCHANT["item_class"], "only weapons or only armor"),
    "item_level": (_INT, "only items of this level"),
}


def openapi(prefix="/v1", auth=False):
    problem = {"description": "The request cannot be answered",
               "content": {"application/problem+json": {"schema": _REF("Problem")}}}

    def get(summary, schema, names=(), path_names=(), open_to_all=False):
        if isinstance(schema, list):
            schema = _obj({"data": {"type": "array", "items": _REF(schema[0])}, "next_cursor": {"type": ["string", "null"]}})
        elif isinstance(schema, str):
            schema = _REF(schema)
        parameters = [{"name": name, "in": "path", "required": True, "schema": _INT} for name in path_names]
        parameters += [{"name": name, "in": "query", "schema": PARAMETERS[name][0], "description": PARAMETERS[name][1]}
                       for name in names]
        responses = {"200": {"description": "OK", "content": {"application/json": {"schema": schema}}},
                     "304": {"description": "Not changed since the ETag given in If-None-Match"}, "400": problem}
        if path_names:
            responses["404"] = problem
        operation = {"summary": summary, "parameters": parameters, "responses": responses}
        if open_to_all:
            operation["security"] = []
        elif auth:
            responses["401"] = problem
        return {"get": operation}

    paths = {"/": get("What the service holds and where each collection is", "Root"),
             "/openapi.json": get("This document", {"type": "object"}, open_to_all=True)}
    for path, names, _handler, schema, summary in ROUTES:
        paths[path] = get(summary, schema, names, re.findall(r"\{(\w+)\}", path))
    return {"openapi": "3.1.0",
            "info": {"title": "RookieLedger", "version": "1.0.0", "license": {"name": "MIT"},
                     "description": "What the players' RookieLedger records say together. Read-only, public, totals only. "
                                    + lc.NOTICE},
            "servers": [{"url": prefix}], "paths": paths, "security": [{"key": []}] if auth else [],
            "components": {"schemas": SCHEMAS, "securitySchemes": {"key": {
                "type": "http", "scheme": "bearer",
                "description": "A key of this API, asked of who runs it. Needed only where `security` names it."}}}}


# The service --------------------------------------------------------------------------------------------------------

def _open(db_path):
    path = Path(db_path).absolute()
    return sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=30) if path.exists() else None


def read_keys(db_path):
    """The hashes of the keys that are valid now."""
    con = _open(db_path)
    if not con:
        return set()
    try:
        return {row[0] for row in con.execute("SELECT key_hash FROM api_keys WHERE revoked_at IS NULL")}
    except sqlite3.OperationalError:   # a database made before the API had keys
        return set()
    finally:
        con.close()


def read_database(db_path, known=None):
    """(signature, records, time of the last upload): the signature changes when the records may have. When it is
    still `known`, records is None: the records it stands for are not read and parsed again."""
    con = _open(db_path)
    if not con:
        return None, {}, None
    try:
        # What counts changes with the uploads and with time: a token's probation ends without any upload.
        signature = con.execute("SELECT COUNT(*), COALESCE(SUM(r.rev), 0), COALESCE(MAX(r.received_at), '') "
                                + lc.COUNTED, (lc.probation_ends_before(),)).fetchone()
        if known is not None and signature == known:
            return signature, None, signature[2] or None
        return signature, lc.current_records(con), signature[2] or None
    except sqlite3.OperationalError as error:
        if "no such table" not in str(error):
            raise   # a database of an older server/: the upload service brings it up to date when it starts
        return None, {}, None   # a database no upload service has opened yet
    finally:
        con.close()


class Store:
    """The current View, rebuilt when a look at the database (every REFRESH seconds) shows new uploads."""

    def __init__(self, db_path):
        self.db_path, self.lock, self.looked_at, self.signature, self.view = db_path, threading.Lock(), 0.0, None, None
        self.keys, self.keys_read_at = set(), None

    def known_key(self, key):
        with self.lock:
            now = time.monotonic()
            if self.keys_read_at is None or now - self.keys_read_at > REFRESH:
                self.keys, self.keys_read_at = read_keys(self.db_path), now
            return lc.token_hash(key) in self.keys

    def current(self):
        with self.lock:
            now = time.monotonic()
            if self.view is None or now - self.looked_at > REFRESH:
                # The records are read and parsed again only when the signature moved; else records is None.
                known = None if self.view is None else self.signature
                signature, records, updated_at = read_database(self.db_path, known)
                if self.view is None or signature != self.signature:
                    self.signature, self.view = signature, View(records, updated_at)
                self.looked_at = now
            return self.view


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, db_path, prefix="/v1", auth="none"):
        if auth not in AUTH_MODES:
            raise ValueError("auth is one of: " + ", ".join(AUTH_MODES))
        self.store, self.prefix, self.auth = Store(db_path), prefix.rstrip("/"), auth == "key"
        super().__init__(address, Handler)


class Handler(BaseHTTPRequestHandler):
    server: Server
    protocol_version = "HTTP/1.1"
    server_version = "ledger"
    sys_version = ""
    timeout = 20   # per socket operation: a client that stalls is dropped

    def send(self, status, body=b"", content_type="application/json", headers=()):
        self.send_response(status)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("X-Content-Type-Options", "nosniff")
        for name, value in headers:
            self.send_header(name, value)
        if body:
            self.send_header("Content-Type", content_type)
        if status not in (204, 304):   # never on a 204, and not needed on a 304 (RFC 9110, 8.6)
            self.send_header("Content-Length", str(len(body)))
        # A request body is never read: after one, close, or its bytes would be taken for the next request.
        if self.headers.get("Content-Length", "0").strip() != "0" or "Transfer-Encoding" in self.headers:
            self.send_header("Connection", "close")
            self.close_connection = True
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def problem(self, status, detail, headers=()):
        body = {"type": "about:blank", "title": TITLES[status], "status": status, "detail": detail}
        self.send(status, json.dumps(body).encode(), "application/problem+json",
                  (("Cache-Control", "no-store"),) + tuple(headers))

    def do_GET(self):
        url = urlsplit(self.path)
        prefix = self.server.prefix
        if url.path == "/healthz":
            return self.send(200, lc.HEALTH, headers=(("Cache-Control", "no-store"),))
        if url.path != prefix and not url.path.startswith(prefix + "/"):
            return self.problem(404, "no such resource; GET %s lists them" % prefix)
        auth = self.server.auth
        if auth and url.path != prefix + "/openapi.json":
            scheme, _, given = self.headers.get("Authorization", "").partition(" ")
            if scheme.lower() != "bearer" or not self.server.store.known_key(given.strip()):
                return self.problem(401, "this API asks for a key: Authorization: Bearer <key>",
                                    (("WWW-Authenticate", 'Bearer realm="rookieledger"'),))
        try:
            view = self.server.store.current()
            key = (url.path, url.query)
            # Read once: another request's thread may empty the cache between two looks at it.
            whole = key == (prefix + "/places", "")
            entry = view.kept if whole else view.cache.get(key)
            if entry is None and whole:
                entry = self.keep_places(view, prefix, auth)
            elif entry is None:
                document = answer(view, url.path[len(prefix):], url.query, prefix, auth)
                raw = json.dumps(document, separators=(",", ":")).encode()
                packed = gzip.compress(raw, 6, mtime=0)
                if len(view.cache) >= MAX_CACHED or view.cached_bytes + len(raw) + len(packed) > MAX_CACHED_BYTES:
                    view.cache.clear()
                    view.cached_bytes = 0
                entry = view.cache[key] = (raw, packed, 'W/"%s"' % hashlib.sha256(raw).hexdigest()[:20])
                view.cached_bytes += len(raw) + len(packed)
            raw, packed, etag = entry
        except ApiError as error:
            return self.problem(error.status, error.detail)
        except Exception as error:   # the client learns nothing of it; the log does
            sys.stderr.write(("error on %s: %r" % (url.path, error)).translate(lc.LOG_SAFE) + "\n")
            return self.problem(500, "the service failed to answer")
        headers = (("ETag", etag), ("Cache-Control", "%s, max-age=%d" % ("private" if auth else "public", MAX_AGE)),
                   ("Vary", "Accept-Encoding, Authorization" if auth else "Accept-Encoding"))
        if etag in [tag.strip() for tag in self.headers.get("If-None-Match", "").split(",")]:
            return self.send(304, headers=headers)
        if re.search(r"\bgzip\b(?!\s*;\s*q=0(\.0*)?\s*(,|$))", self.headers.get("Accept-Encoding", "")):
            return self.send(200, packed, headers=headers + (("Content-Encoding", "gzip"),))
        self.send(200, raw, headers=headers)

    def keep_places(self, view, prefix, auth):
        """Makes /places once per state of the database, and tells the log how large it has become: that size, as
        the records grow, is what says when a map page should stop loading every place at once."""
        with view.making:
            if view.kept is None:
                started = time.monotonic()
                raw = json.dumps(answer(view, "/places", "", prefix, auth), separators=(",", ":")).encode()
                packed = gzip.compress(raw, 6, mtime=0)
                view.kept = (raw, packed, 'W/"%s"' % hashlib.sha256(raw).hexdigest()[:20])
                sys.stderr.write("%s places document: %d places, %d bytes, %d gzipped, made in %.2f s%s\n" % (
                    time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), len(view.node_places) + len(view.creature_places),
                    len(raw), len(packed), time.monotonic() - started,
                    " (over %d MiB gzipped: time to load less at once)" % (PLACES_WARN // 2**20)
                    if len(packed) > PLACES_WARN else ""))
            return view.kept

    do_HEAD = do_GET

    def do_OPTIONS(self):
        self.send(204, headers=(("Allow", "GET, HEAD, OPTIONS"), ("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS"),
                                ("Access-Control-Allow-Headers", "Authorization, If-None-Match"), ("Access-Control-Max-Age", "86400")))

    def refuse(self):
        self.problem(405, "this API only reads: GET, HEAD or OPTIONS", (("Allow", "GET, HEAD, OPTIONS"),))

    do_POST = do_PUT = do_PATCH = do_DELETE = refuse

    def log_message(self, format, *args):
        # One line per request, without the client's address.
        sys.stderr.write("%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                                      (format % args).translate(lc.LOG_SAFE)))


def main():
    ap = argparse.ArgumentParser(description="Read API of RookieLedger")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8788)
    ap.add_argument("--db", type=Path, default=lc.DB_PATH)
    ap.add_argument("--prefix", default="/v1", help="path the API answers under (default /v1)")
    ap.add_argument("--auth", choices=AUTH_MODES, default=os.environ.get("LEDGER_API_AUTH") or "none",
                    help="none: answer everyone (default). key: ask for a key made with ledger_admin.py api-key add")
    args = ap.parse_args()
    server = Server((args.host, args.port), args.db, args.prefix, args.auth)
    print(f"ledger api on {args.host}:{args.port}{server.prefix}, auth {args.auth}, database {args.db}",
          file=sys.stderr, flush=True)
    lc.serve(server)


if __name__ == "__main__":
    main()
