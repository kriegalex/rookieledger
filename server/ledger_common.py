#!/usr/bin/env python3
"""Server side of the RookieLedger addon (addon/RookieLedger): read an uploaded saved-variables file, check it, store it.

The addon writes `RookieLedgerDB` to `WTF/Account/<account>/SavedVariables/RookieLedger.lua`; the companion app
(companion/) uploads that file as it is. Nothing in it is ever executed: `parse_saved_variables` reads the Lua table
literal the game writes (strings, numbers, booleans, nested tables) and refuses anything else, and `check_db` keeps only
records whose every field is a whole number inside the bounds the addon itself applies (Record.lua).

A record is one WoW account's observations, named by an 8-hex id (no character name):
  c[recipe] = [profession, lo0, hi0, lo1, hi1, lo2, hi2, lo3, hi3]   skill range seen per colour (0 orange .. 3 grey)
  s["recipe:skill:colour"] = [crafts, skill-ups]
  d[item] = {l: item level, q: quality, k: class (2 weapon, 4 armor), n: disenchants, m: {material: [quantity, times]}}
An upload carries the uploader's own record and the ones it received from guild members in game. `data/ledger.sqlite`
keeps one row per (record id, uploader) and `current_records` picks one per id: the author's own upload when there is
one, else the highest change counter. Counts are never added across uploads, so sending a file twice changes nothing.
"""
import hashlib, json, re, sqlite3, time
from pathlib import Path

ROOT = Path(__file__).absolute().parent.parent
DB_PATH = ROOT / "data" / "ledger.sqlite"

MAX_ID = 9_999_999
MAX_SKILL = 600
MAX_COUNT = 1_000_000
MAX_PEERS = 300
MAX_ENTRIES = 6000          # per record, as in Record.lua
MAX_DEPTH = 8
MAX_VALUES = 1_000_000      # per file: the game spends 9 bytes or more on a value, so the 8 MiB an upload may hold stay
                            # under it, while 8 MiB of "0," would otherwise become 4 million table entries in memory
TOKEN_RE = re.compile(r"[0-9a-f]{32}")
ID_RE = re.compile(r"[0-9a-f]{8}")


class LedgerError(ValueError):
    """The upload is not what the addon writes."""


# The saved-variables file -------------------------------------------------------------------------------------------

_TOKEN = re.compile(r"""
    \s+ | --[^\n]*                                   # blanks and comments (the game writes "-- [1]" after array items)
  | (?P<str>"(?:[^"\\\n]|\\.)*")
  | (?P<num>-?(?:0x[0-9a-fA-F]+|\d+\.?\d*(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?))
  | (?P<name>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<punct>[{}\[\]=,;])
""", re.X | re.S)
_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "'": "'", "\n": "\n", "a": "\a", "b": "\b",
            "f": "\f", "v": "\v"}


def _tokens(text):
    pos = 0
    while pos < len(text):
        m = _TOKEN.match(text, pos)
        if not m:
            raise LedgerError(f"unexpected text at offset {pos}")
        pos = m.end()
        if m.lastgroup:
            yield m.lastgroup, m.group(m.lastgroup)
    yield "end", ""


def _unescape(literal):
    def one(m):
        code = m.group(1)
        if code.isdigit():
            return chr(int(code))
        if code not in _ESCAPES:
            raise LedgerError("unknown string escape")
        return _ESCAPES[code]
    return re.sub(r"\\(\d{1,3}|.)", one, literal[1:-1], flags=re.S)


class _Parser:
    def __init__(self, text):
        self.tokens = _tokens(text)
        self.values = 0
        self.kind, self.value = next(self.tokens)

    def advance(self):
        self.kind, self.value = next(self.tokens)

    def expect(self, punct):
        if self.kind != "punct" or self.value != punct:
            raise LedgerError(f"expected {punct!r}")
        self.advance()

    def scalar(self):
        kind, value = self.kind, self.value
        if kind == "str":
            self.advance()
            return _unescape(value)
        if kind == "num":
            self.advance()
            if value.lower().startswith(("0x", "-0x")):
                return int(value, 16)
            number = float(value)
            return int(number) if number.is_integer() and abs(number) < 2**53 else number
        if kind == "name" and value in ("true", "false", "nil"):
            self.advance()
            return {"true": True, "false": False, "nil": None}[value]
        raise LedgerError("expected a value")

    def value_(self, depth):
        if self.kind == "punct" and self.value == "{":
            return self.table(depth + 1)
        return self.scalar()

    def table(self, depth):
        if depth > MAX_DEPTH:
            raise LedgerError("tables nested too deep")
        self.expect("{")
        out, index = {}, 1
        while not (self.kind == "punct" and self.value == "}"):
            if self.kind == "punct" and self.value == "[":
                self.advance()
                key = self.scalar()
                self.expect("]")
                self.expect("=")
            elif self.kind == "name" and self.value not in ("true", "false", "nil"):
                key = self.value
                self.advance()
                self.expect("=")
            else:
                key, index = index, index + 1
            if isinstance(key, (dict, bool, float)) or key is None:
                raise LedgerError("unusable table key")
            self.values += 1
            if self.values > MAX_VALUES:
                raise LedgerError("too many values")
            out[key] = self.value_(depth)
            if self.kind == "punct" and self.value in ",;":
                self.advance()
            elif not (self.kind == "punct" and self.value == "}"):
                raise LedgerError("expected ',' or '}'")
        self.advance()
        return out


def parse_saved_variables(text):
    """{global name: value} for a saved-variables file: a list of `Name = <literal>` assignments, nothing else."""
    parser = _Parser(text)
    out = {}
    while parser.kind != "end":
        if parser.kind != "name":
            raise LedgerError("expected an assignment")
        name = parser.value
        parser.advance()
        parser.expect("=")
        out[name] = parser.value_(0)
    return out


# Checking -----------------------------------------------------------------------------------------------------------

def _int(value, lo, hi):
    if isinstance(value, bool) or not isinstance(value, int) or not lo <= value <= hi:
        raise LedgerError(f"number out of range: {value!r}")
    return value


def _array(value, length):
    """The game writes a Lua array as keys 1..n."""
    if not isinstance(value, dict) or len(value) != length or any(i not in value for i in range(1, length + 1)):
        raise LedgerError("expected a list of %d numbers" % length)
    return [value[i] for i in range(1, length + 1)]


def check_record(raw):
    """The record as JSON-ready data, or LedgerError. Mirrors Record.Parse in the addon."""
    if not isinstance(raw, dict):
        raise LedgerError("record is not a table")
    colours, crafts, disenchants = raw.get("c") or {}, raw.get("s") or {}, raw.get("d") or {}
    if not all(isinstance(t, dict) for t in (colours, crafts, disenchants)):
        raise LedgerError("record sections are not tables")
    if len(colours) + len(crafts) + len(disenchants) > MAX_ENTRIES:
        raise LedgerError("record too large")
    rec = {"rev": _int(raw.get("rev", 0), 0, 10**9), "t": _int(raw.get("t", 0), 0, 2**32 - 1),
           "b": _int(raw.get("b", 0), 0, 10**9), "c": {}, "s": {}, "d": {}}
    for recipe, entry in colours.items():
        entry = _array(entry, 9)
        _int(recipe, 1, MAX_ID), _int(entry[0], 1, MAX_ID)
        for colour in range(4):
            lo, hi = _int(entry[1 + colour * 2], 0, MAX_SKILL), _int(entry[2 + colour * 2], 0, MAX_SKILL)
            if lo > hi or (lo == 0) != (hi == 0):
                raise LedgerError("bad skill range")
        rec["c"][str(recipe)] = entry
    for key, counts in crafts.items():
        m = re.fullmatch(r"(\d{1,7}):(\d{1,3}):([0-3])", key) if isinstance(key, str) else None
        if not m:
            raise LedgerError("bad craft key")
        _int(int(m.group(1)), 1, MAX_ID), _int(int(m.group(2)), 1, MAX_SKILL)
        made, ups = _array(counts, 2)
        if _int(ups, 0, MAX_COUNT) > _int(made, 1, MAX_COUNT) * 5:
            raise LedgerError("more skill-ups than crafts allow")
        rec["s"][f"{int(m.group(1))}:{int(m.group(2))}:{m.group(3)}"] = [made, ups]
    for item, entry in disenchants.items():
        if not isinstance(entry, dict) or not isinstance(entry.get("m") or {}, dict):
            raise LedgerError("bad disenchant entry")
        n = _int(entry.get("n"), 1, MAX_COUNT)
        if _int(entry.get("k"), 2, 4) == 3:
            raise LedgerError("bad item class")
        materials = {}
        for material, pair in (entry.get("m") or {}).items():
            quantity, times = _array(pair, 2)
            _int(material, 1, MAX_ID), _int(times, 1, n), _int(quantity, times, times * 20)
            materials[str(material)] = [quantity, times]
        rec["d"][str(_int(item, 1, MAX_ID))] = {"l": _int(entry.get("l"), 1, 1000), "q": _int(entry.get("q"), 2, 4),
                                                 "k": entry["k"], "n": n, "m": materials}
    return rec


def check_db(saved):
    """(id, own record, {peer id: record}) from a parsed saved-variables file. A peer that fails the checks is left
    out (it came from someone else's client); a bad own record refuses the upload."""
    db = saved.get("RookieLedgerDB")
    if not isinstance(db, dict) or db.get("v") != 1:
        raise LedgerError("no RookieLedgerDB of format 1")
    origin = db.get("id")
    if not isinstance(origin, str) or not ID_RE.fullmatch(origin):
        raise LedgerError("bad record id")
    own = check_record(db.get("own"))
    peers = {}
    raw_peers = db.get("peers") or {}
    if not isinstance(raw_peers, dict) or len(raw_peers) > MAX_PEERS:
        raise LedgerError("bad peers table")
    for peer, raw in raw_peers.items():
        if isinstance(peer, str) and ID_RE.fullmatch(peer) and peer != origin:
            try:
                peers[peer] = check_record(raw)
            except LedgerError:
                pass
    return origin, own, peers


def file_token(text):
    """The upload token the addon stored in a saved-variables file, or None."""
    m = re.search(r'\["token"\] = "([0-9a-f]{32})"', text)
    return m.group(1) if m else None


# Storage ------------------------------------------------------------------------------------------------------------

def token_hash(token):
    return hashlib.sha256(token.encode()).hexdigest()


def connect(path=DB_PATH):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(path, timeout=30)
    con.execute("PRAGMA journal_mode=WAL")
    con.executescript("""
        CREATE TABLE IF NOT EXISTS ledger_tokens (
            token_hash TEXT PRIMARY KEY,   -- SHA-256 of the token: the token itself is never stored
            label TEXT NOT NULL,
            added_at TEXT NOT NULL,
            revoked_at TEXT,
            last_upload TEXT,
            origin TEXT                    -- the record id this token last uploaded as its own
        );
        CREATE TABLE IF NOT EXISTS ledger_records (
            origin TEXT NOT NULL,          -- the record's 8-hex id
            uploader TEXT NOT NULL,        -- token_hash of who sent it
            own INTEGER NOT NULL,          -- 1 when the uploader is the record's author
            rev INTEGER NOT NULL,
            build INTEGER NOT NULL,
            changed_at INTEGER NOT NULL,   -- the record's own clock (epoch seconds)
            received_at TEXT NOT NULL,
            body TEXT NOT NULL,            -- the checked record as JSON
            PRIMARY KEY (origin, uploader)
        );
    """)
    return con


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime())


def add_token(con, token, label):
    if not TOKEN_RE.fullmatch(token):
        raise LedgerError("a token is 32 hex digits, as /ledger token shows it")
    con.execute("INSERT INTO ledger_tokens (token_hash, label, added_at) VALUES (?, ?, ?) "
                "ON CONFLICT(token_hash) DO UPDATE SET label = excluded.label, revoked_at = NULL",
                (token_hash(token), label, now_iso()))
    con.commit()


def revoke_token(con, token_or_label):
    key = token_hash(token_or_label) if TOKEN_RE.fullmatch(token_or_label) else None
    cur = con.execute("UPDATE ledger_tokens SET revoked_at = ? WHERE revoked_at IS NULL AND (token_hash = ? OR label = ?)",
                      (now_iso(), key, token_or_label))
    con.commit()
    return cur.rowcount


def active_hashes(con):
    return {row[0] for row in con.execute("SELECT token_hash FROM ledger_tokens WHERE revoked_at IS NULL")}


def store_upload(con, uploader, origin, own, peers):
    """Keeps each record unless this uploader already sent the same or a newer one. Returns how many rows changed."""
    stamp, changed = now_iso(), 0
    for rec_id, rec, is_own in [(origin, own, 1)] + [(peer, rec, 0) for peer, rec in peers.items()]:
        if rec["rev"] < 1:
            continue
        row = con.execute("SELECT rev FROM ledger_records WHERE origin = ? AND uploader = ?", (rec_id, uploader)).fetchone()
        if row and row[0] >= rec["rev"]:
            continue
        con.execute("INSERT OR REPLACE INTO ledger_records VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    (rec_id, uploader, is_own, rec["rev"], rec["b"], rec["t"], stamp, json.dumps(rec, separators=(",", ":"))))
        changed += 1
    con.execute("UPDATE ledger_tokens SET last_upload = ?, origin = ? WHERE token_hash = ?", (stamp, origin, uploader))
    con.commit()
    return changed


def current_records(con):
    """{record id: record}: one per account, from uploaders whose token is still valid. The author's own upload wins
    over a copy relayed by someone else; among copies the highest change counter wins."""
    out, best = {}, {}
    for origin, own, rev, body in con.execute(
            "SELECT r.origin, r.own, r.rev, r.body FROM ledger_records r JOIN ledger_tokens t ON t.token_hash = r.uploader "
            "WHERE t.revoked_at IS NULL"):
        rank = (own, rev)
        if origin not in best or rank > best[origin]:
            best[origin], out[origin] = rank, json.loads(body)
    return out


# What the records say -----------------------------------------------------------------------------------------------

def colour_thresholds(records):
    """{recipe: {"profession", "ranges": [(lo, hi) or None per colour], "yellow"/"green"/"grey": (after, by) or None,
    "conflict": bool}} over every record. A colour change lies in (after, by]: the highest skill seen in the earlier
    colour and the lowest seen in the later one. "conflict" marks ranges that overlap between colours, which means a
    wrong observation or a threshold the game moved."""
    merged = {}
    for rec in records.values():
        for recipe, entry in rec["c"].items():
            m = merged.setdefault(int(recipe), {"profession": entry[0], "ranges": [None] * 4})
            for colour in range(4):
                lo, hi = entry[1 + colour * 2], entry[2 + colour * 2]
                if lo:
                    old = m["ranges"][colour]
                    m["ranges"][colour] = (min(lo, old[0]), max(hi, old[1])) if old else (lo, hi)
    for m in merged.values():
        seen = [(colour, r) for colour, r in enumerate(m["ranges"]) if r]
        m["conflict"] = any(a[1][1] >= b[1][0] for a, b in zip(seen, seen[1:]))
        for colour, name in ((1, "yellow"), (2, "green"), (3, "grey")):
            before, after = m["ranges"][colour - 1], m["ranges"][colour]
            m[name] = (before[1], after[0]) if before and after and before[1] < after[0] else None
    return merged


def skill_up_rates(records):
    """{(recipe, colour): (crafts, skill-ups)} summed over every record."""
    out = {}
    for rec in records.values():
        for key, (made, ups) in rec["s"].items():
            recipe, _skill, colour = key.split(":")
            a = out.get((int(recipe), int(colour)), (0, 0))
            out[(int(recipe), int(colour))] = (a[0] + made, a[1] + ups)
    return out


def disenchant_yields(records):
    """{(quality, class, item level): {"n": disenchants, "materials": {material: (average quantity per disenchant,
    share of disenchants that gave it)}}} summed over every record."""
    acc = {}
    for rec in records.values():
        for entry in rec["d"].values():
            a = acc.setdefault((entry["q"], entry["k"], entry["l"]), {"n": 0, "m": {}})
            a["n"] += entry["n"]
            for material, (quantity, times) in entry["m"].items():
                q, t = a["m"].get(int(material), (0, 0))
                a["m"][int(material)] = (q + quantity, t + times)
    return {key: {"n": a["n"], "materials": {m: (q / a["n"], t / a["n"]) for m, (q, t) in a["m"].items()}}
            for key, a in acc.items()}
