#!/usr/bin/env python3
"""Upload endpoint of the RookieLedger companion app: the one part of the site that accepts data.

  python3 -I server/ledger_ingest.py --port 8787 [--db data/ledger.sqlite]

  GET  /api/ledger/v1/status   204 when the bearer token is registered, 401 otherwise
  POST /api/ledger/v1/upload   a RookieLedger.lua saved-variables file (optionally gzip), 200 with a JSON summary

Every request carries `Authorization: Bearer <token>`, the 32 hex digits the addon shows with /ledger token. The token
is looked up (its SHA-256, in memory) before anything else: an unknown one gets 401 and the connection is closed
without the body being read, so an unregistered or revoked app costs one header parse. Tokens are registered by hand
with server/ledger_admin.py. A registered token may upload once every MIN_INTERVAL seconds, at most MAX_BODY bytes;
the file is parsed as data and checked field by field (server/ledger_common.py), never executed. A token writes one
record id as its own, the one of its first upload: another id is answered 409.
"""
import argparse, json, sys, threading, time, zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
sys.path.insert(0, str(Path(__file__).absolute().parent))
import ledger_common as lc

PREFIX = "/api/ledger/v1/"
MAX_BODY = 1 * 2**20        # as sent; a year of one account's data is tens of kB
MAX_TEXT = 8 * 2**20        # after gunzip
MIN_INTERVAL = 20           # seconds between two uploads of one token
TOKEN_CACHE = 15            # seconds the list of registered tokens is kept in memory


class Tokens:
    """The registered token hashes, re-read from the database every TOKEN_CACHE seconds."""

    def __init__(self, db_path):
        self.db_path, self.lock = db_path, threading.Lock()
        self.hashes, self.read_at, self.last_upload = set(), 0.0, {}

    def known(self, token):
        if not lc.TOKEN_RE.fullmatch(token):
            return None
        with self.lock:
            if time.monotonic() - self.read_at > TOKEN_CACHE:
                con = lc.connect(self.db_path)
                try:
                    self.hashes = lc.active_hashes(con)
                finally:
                    con.close()
                self.read_at = time.monotonic()
            digest = lc.token_hash(token)
            return digest if digest in self.hashes else None

    def may_upload(self, digest):
        with self.lock:
            now = time.monotonic()
            if now - self.last_upload.get(digest, -MIN_INTERVAL) < MIN_INTERVAL:
                return False
            self.last_upload[digest] = now
            return True


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, db_path):
        lc.connect(db_path).close()   # create the tables before the first request
        self.db_path, self.tokens = db_path, Tokens(db_path)
        super().__init__(address, Handler)


class Handler(BaseHTTPRequestHandler):
    server: Server
    protocol_version = "HTTP/1.1"
    server_version = "ledger"
    sys_version = ""
    timeout = 20   # per socket operation: a client that stalls is dropped

    def reply(self, status, body=None, close=False):
        data = json.dumps(body).encode() if body is not None else b""
        self.send_response(status)
        if data:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        if close:
            self.send_header("Connection", "close")
            self.close_connection = True
        self.end_headers()
        self.wfile.write(data)

    def authorised(self):
        """The uploader's token hash, or None after answering 401 (body unread, connection closed)."""
        scheme, _, token = self.headers.get("Authorization", "").partition(" ")
        digest = self.server.tokens.known(token.strip()) if scheme == "Bearer" else None
        if not digest:
            self.reply(401, close=True)
        return digest

    def do_GET(self):
        if self.path != PREFIX + "status":
            return self.reply(404, close=True)
        if self.authorised():
            # A body sent with the question is never read: close, or its bytes would be taken for the next request.
            unread = self.headers.get("Content-Length", "0").strip() != "0" or "Transfer-Encoding" in self.headers
            self.reply(204, close=unread)

    def do_POST(self):
        if self.path != PREFIX + "upload":
            return self.reply(404, close=True)
        digest = self.authorised()
        if not digest:
            return
        # ASCII digits, few enough for int(): isdigit() alone also accepts "²", which int() refuses.
        length = self.headers.get("Content-Length", "")
        sized = length.isascii() and length.isdigit() and len(length) <= 9 and "Transfer-Encoding" not in self.headers
        if not sized or not 0 < int(length) <= MAX_BODY:
            return self.reply(413, {"error": "body missing or too large"}, close=True)
        if not self.server.tokens.may_upload(digest):
            return self.reply(429, {"error": "one upload every %d seconds" % MIN_INTERVAL}, close=True)
        data = self.rfile.read(int(length))
        try:
            if self.headers.get("Content-Encoding") == "gzip":
                inflater = zlib.decompressobj(31)
                data = inflater.decompress(data, MAX_TEXT)
                if inflater.unconsumed_tail:
                    raise lc.LedgerError("file too large")
            if len(data) > MAX_TEXT:
                raise lc.LedgerError("file too large")
            origin, own = lc.check_db(lc.parse_saved_variables(data.decode("utf-8")))
        except (lc.LedgerError, zlib.error, UnicodeDecodeError, RecursionError) as error:
            return self.reply(400, {"error": str(error)})
        con = lc.connect(self.server.db_path)
        try:
            changed = lc.store_upload(con, digest, origin, own)
        except lc.LedgerConflict as error:
            return self.reply(409, {"error": str(error)})
        finally:
            con.close()
        self.reply(200, {"id": origin, "rev": own["rev"], "stored": changed, "skipped": own.get("skipped", 0)})

    def log_message(self, format, *args):
        # One line per request, without the Authorization header and without the client's address.
        sys.stderr.write("%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), format % args))


def main():
    ap = argparse.ArgumentParser(description="Upload endpoint of the RookieLedger companion app")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--db", type=Path, default=lc.DB_PATH)
    args = ap.parse_args()
    server = Server((args.host, args.port), args.db)
    print(f"ledger ingest on {args.host}:{args.port}, database {args.db}", file=sys.stderr, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
