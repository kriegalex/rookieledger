#!/usr/bin/env python3
"""Upload endpoint of the RookieLedger companion app: the one part of the site that accepts data.

  python3 -I server/ledger_ingest.py --port 8787 [--db data/ledger.sqlite] [--registration closed|open]

  GET  /v1/ledger/status   204 when the bearer token is registered, 401 otherwise
  POST /v1/ledger/upload   a RookieLedger.lua saved-variables file (optionally gzip), 200 with a JSON summary
                           of the record it holds. The log of groups in the same file is kept apart, for study
  GET  /healthz            200 while the process answers, with the version of the service; no token needed

Every request carries `Authorization: Bearer <token>`, the 32 hex digits the addon shows with /ledger token. The token
is looked up (its SHA-256, in memory) before anything else: an unknown one gets 401 and the connection is closed
without the body being read, so an unregistered or revoked app costs one header parse. Tokens are registered by hand
with server/ledger_admin.py. A registered token may upload once every MIN_INTERVAL seconds, at most MAX_BODY bytes;
the file is parsed as data and checked field by field (server/ledger_common.py), never executed. A token writes one
record id as its own, the one of its first upload: another id is answered 409.

With `--registration open` (or LEDGER_REGISTRATION=open in the environment; closed unless asked for) nobody registers
tokens by hand: a token the site never saw is told "known" by /status and registers itself with its first upload that
passes the checks, as `self-<record id>`. The companion app needs no change for it. The token stays the secret that
ties a record to who made it, and a revoked one stays shut out. What an open site gives up is the body left unread:
it reads up to MAX_BODY bytes from a stranger, at most MAX_UNKNOWN_PER_MINUTE times a minute, and lets
MAX_SELF_PER_DAY tokens register per day. It also takes what a stranger's record says at its word, within the bounds
of the checks: who runs an open site should watch what comes in.
"""
import argparse, json, os, sys, threading, time, zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
sys.path.insert(0, str(Path(__file__).absolute().parent))
import ledger_common as lc

PREFIX = "/v1/ledger/"
MAX_BODY = 1 * 2**20        # as sent; a year of one account's data is tens of kB
MAX_TEXT = 8 * 2**20        # after gunzip
MIN_INTERVAL = 20           # seconds between two uploads of one token
TOKEN_CACHE = 15            # seconds the list of registered tokens is kept in memory
REGISTRATION = ("closed", "open")
MAX_SELF_PER_DAY = 50       # tokens that may register themselves in 24 hours on an open site
MAX_UNKNOWN_PER_MINUTE = 30 # uploads read from tokens not yet registered, all of them together


class Tokens:
    """The registered token hashes, re-read from the database every TOKEN_CACHE seconds."""

    def __init__(self, db_path, open_to_all=False):
        self.db_path, self.lock, self.open = db_path, threading.Lock(), open_to_all
        self.hashes, self.revoked, self.read_at, self.last_upload, self.unknown = set(), set(), 0.0, {}, []
        self.pruned_at = 0.0

    def known(self, token):
        """(token hash, registered) of a token that may upload, or None. On an open site a token never seen may
        upload too, as not registered yet; a revoked one may not."""
        if not lc.TOKEN_RE.fullmatch(token):
            return None
        with self.lock:
            if time.monotonic() - self.read_at > TOKEN_CACHE:
                con = lc.connect(self.db_path)
                try:
                    self.hashes, self.revoked = lc.active_hashes(con), lc.revoked_hashes(con)
                finally:
                    con.close()
                self.read_at = time.monotonic()
            digest = lc.token_hash(token)
            if digest in self.hashes:
                return digest, True
            return (digest, False) if self.open and digest not in self.revoked else None

    def registered(self, digest):
        with self.lock:
            self.hashes.add(digest)

    def may_read_unknown(self):
        """False once MAX_UNKNOWN_PER_MINUTE uploads of tokens not yet registered were read within a minute."""
        with self.lock:
            now = time.monotonic()
            self.unknown = [t for t in self.unknown if now - t < 60]
            if len(self.unknown) >= MAX_UNKNOWN_PER_MINUTE:
                return False
            self.unknown.append(now)
            return True

    def may_upload(self, digest):
        with self.lock:
            now = time.monotonic()
            if now - self.pruned_at >= MIN_INTERVAL:
                # Only the last MIN_INTERVAL counts. On an open site every made-up token passes here: kept for good,
                # each would hold memory until the process ends.
                self.last_upload = {d: t for d, t in self.last_upload.items() if now - t < MIN_INTERVAL}
                self.pruned_at = now
            if now - self.last_upload.get(digest, -MIN_INTERVAL) < MIN_INTERVAL:
                return False
            self.last_upload[digest] = now
            return True


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, db_path, registration="closed"):
        if registration not in REGISTRATION:
            raise ValueError("registration is one of: " + ", ".join(REGISTRATION))
        lc.connect(db_path).close()   # create the tables before the first request
        self.db_path, self.tokens = db_path, Tokens(db_path, registration == "open")
        self.parsing = threading.Lock()   # see do_POST
        super().__init__(address, Handler)


class Handler(BaseHTTPRequestHandler):
    server: Server
    protocol_version = "HTTP/1.1"
    server_version = "ledger"
    sys_version = ""
    timeout = 20   # per socket operation: a client that stalls is dropped

    def reply(self, status, body=None, close=False):
        if status in (401, 404) and body is None:
            body = {"notice": lc.NOTICE}   # to who knocks without being a member's app: what this door is for
        data = json.dumps(body).encode() if body is not None else b""
        self.send_response(status)
        if data:
            self.send_header("Content-Type", "application/json")
        if status != 204:   # a 204 has no body and never says its length (RFC 9110, 8.6)
            self.send_header("Content-Length", str(len(data)))
        if close:
            self.send_header("Connection", "close")
            self.close_connection = True
        self.end_headers()
        self.wfile.write(data)

    def authorised(self):
        """(the uploader's token hash, whether it is registered), or None after answering 401 (body unread,
        connection closed)."""
        scheme, _, token = self.headers.get("Authorization", "").partition(" ")
        known = self.server.tokens.known(token.strip()) if scheme == "Bearer" else None
        if not known:
            self.reply(401, close=True)
        return known

    def do_GET(self):
        if self.path == "/healthz":   # for the probe of whatever runs the service: it is not below PREFIX
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(lc.HEALTH)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return self.wfile.write(lc.HEALTH)
        if self.path != PREFIX + "status":
            return self.reply(404, close=True)
        if self.authorised():
            # A body sent with the question is never read: close, or its bytes would be taken for the next request.
            unread = self.headers.get("Content-Length", "0").strip() != "0" or "Transfer-Encoding" in self.headers
            self.reply(204, close=unread)

    def do_POST(self):
        if self.path != PREFIX + "upload":
            return self.reply(404, close=True)
        known = self.authorised()
        if not known:
            return
        digest, registered = known
        # ASCII digits, few enough for int(): isdigit() alone also accepts "²", which int() refuses.
        length = self.headers.get("Content-Length", "")
        sized = length.isascii() and length.isdigit() and len(length) <= 9 and "Transfer-Encoding" not in self.headers
        if not sized or not 0 < int(length) <= MAX_BODY:
            return self.reply(413, {"error": "body missing or too large"}, close=True)
        if not self.server.tokens.may_upload(digest):
            return self.reply(429, {"error": "one upload every %d seconds" % MIN_INTERVAL}, close=True)
        if not registered and not self.server.tokens.may_read_unknown():
            return self.reply(429, {"error": "too many new members right now; the app tries again later"}, close=True)
        data = self.rfile.read(int(length))
        try:
            # One file is read at a time. A few kB of gzip can unpack to MAX_VALUES empty tables, which take tens
            # of MiB while they are parsed: several at once would be more than the service's container may hold.
            with self.server.parsing:
                if self.headers.get("Content-Encoding") == "gzip":
                    inflater = zlib.decompressobj(31)
                    data = inflater.decompress(data, MAX_TEXT)
                    if inflater.unconsumed_tail:
                        raise lc.LedgerError("file too large")
                if len(data) > MAX_TEXT:
                    raise lc.LedgerError("file too large")
                saved = lc.parse_saved_variables(data.decode("utf-8"))
                origin, own = lc.check_db(saved)
                group = lc.group_lines(saved)
        except (lc.LedgerError, zlib.error, UnicodeDecodeError, RecursionError) as error:
            return self.reply(400, {"error": str(error)})
        con = lc.connect(self.server.db_path)
        try:
            if not registered:
                lc.self_register(con, digest, origin, MAX_SELF_PER_DAY)
            changed = lc.store_upload(con, digest, origin, own)
            lc.store_group_log(con, origin, group)   # beside the record, never in it: see lc.group_lines
        except lc.LedgerFull as error:
            return self.reply(429, {"error": str(error)})
        except lc.LedgerConflict as error:
            return self.reply(409, {"error": str(error)})
        finally:
            con.close()   # what a refused upload wrote is not committed: its token is not registered
        if not registered:
            self.server.tokens.registered(digest)
        self.reply(200, {"id": origin, "rev": own["rev"], "stored": changed, "skipped": own.get("skipped", 0)})

    def log_request(self, code="-", size="-"):
        if self.path != "/healthz":   # the probes of whatever runs the service, every few seconds
            super().log_request(code, size)

    def log_message(self, format, *args):
        # One line per request, without the Authorization header and without the client's address.
        sys.stderr.write("%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                                      (format % args).translate(lc.LOG_SAFE)))


def main():
    ap = argparse.ArgumentParser(description="Upload endpoint of the RookieLedger companion app")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--db", type=Path, default=lc.DB_PATH)
    ap.add_argument("--registration", choices=REGISTRATION, default=os.environ.get("LEDGER_REGISTRATION") or "closed",
                    help="closed: only tokens registered with ledger_admin.py upload (default). "
                         "open: a new token registers itself with its first upload")
    args = ap.parse_args()
    server = Server((args.host, args.port), args.db, args.registration)
    lc.serve(server, f"ledger ingest on {args.host}:{args.port}, registration {args.registration}, database {args.db}")


if __name__ == "__main__":
    main()
