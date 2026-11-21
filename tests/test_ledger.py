"""RookieLedger: the addon in a simulated game (lua5.1), the saved-variables parser, the checks and the upload endpoint.
No database of the pipeline is needed; the endpoint runs on a free local port with a temporary database."""
import gzip, io, json, os, shutil, socket, sqlite3, subprocess, sys, tempfile, threading, time, unittest, urllib.error
import urllib.request
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).absolute().parent.parent
sys.path.insert(0, str(ROOT / "server"))
import ledger_admin, ledger_common as lc, ledger_ingest

TOKEN = "0123456789abcdef0123456789abcdef"
OTHER = "fedcba9876543210fedcba9876543210"
SAVED = '''
RookieLedgerDB = {
["v"] = 1,
["token"] = "%s",
["id"] = "0876cf1e",
["sync"] = true,
["own"] = {
["rev"] = 7,
["t"] = 1794800000,
["b"] = 70374,
["c"] = {
[7421] = {
333, -- [1]
125, -- [2]
126, -- [3]
0, -- [4]
0, -- [5]
0, -- [6]
0, -- [7]
0, -- [8]
0, -- [9]
},
},
["s"] = {
["7421:125:0"] = {
3, -- [1]
3, -- [2]
},
},
["d"] = {
[2584] = {
["l"] = 16,
["q"] = 2,
["k"] = 4,
["n"] = 2,
["m"] = {
[10940] = {
4, -- [1]
2, -- [2]
},
},
},
},
["g"] = {
[1731] = {
["k"] = 1,
["n"] = 4,
["m"] = {
[2770] = {
9, -- [1]
4, -- [2]
},
[2835] = {
1, -- [1]
1, -- [2]
},
},
["p"] = {
["1429:432:654"] = 3,
["1429:600:200"] = 1,
},
},
},
["m"] = {
[299] = {
["n"] = 4,
["cn"] = 2,
["c"] = 370,
["i"] = {
[2589] = {
5, -- [1]
3, -- [2]
},
[771] = {
1, -- [1]
1, -- [2]
},
},
},
},
},
["peers"] = {
["aaaaaaaa"] = {
["rev"] = 2,
["t"] = 1794700000,
["b"] = 70374,
["at"] = 1794700500,
["c"] = {
[7421] = {
333, -- [1]
0, -- [2]
0, -- [3]
131, -- [4]
140, -- [5]
0, -- [6]
0, -- [7]
0, -- [8]
0, -- [9]
},
},
["s"] = {
},
["d"] = {
},
},
["bbbbbbbb"] = {
["rev"] = 1,
["c"] = {
[7421] = "os.exit()",
},
},
},
}
''' % TOKEN


class Parser(unittest.TestCase):
    def test_reads_what_the_game_writes(self):
        saved = lc.parse_saved_variables('A = {\n["k"] = "a\\"b\\\\c\\n",\n[3] = -1.5,\n7, -- [1]\ntrue, -- [2]\n}\nB = nil\n')
        self.assertEqual(saved, {"A": {"k": 'a"b\\c\n', 3: -1.5, 1: 7, 2: True}, "B": None})

    def test_refuses_code(self):
        for text in ("A = os.exit()", "A = {f()}", "A = {} os.exit()", "A = function() end", "A = {[x] = 1}",
                     "A = 1 + 1", "A = [[long string]]", "local A = 1", "A = {" * 20 + "}" * 20):
            with self.assertRaises(lc.LedgerError, msg=text):
                lc.parse_saved_variables(text)

    def test_refuses_more_values_than_the_game_writes(self):
        with mock.patch.object(lc, "MAX_VALUES", 50):
            self.assertEqual(len(lc.parse_saved_variables("A = {" + "0," * 49 + "}")["A"]), 49)
            for text in ("A = {" + "0," * 51 + "}", "A = {" + "{}," * 30 + "}\nB = {" + "0," * 30 + "}"):
                with self.assertRaises(lc.LedgerError):
                    lc.parse_saved_variables(text)

    def test_token_of_a_file(self):
        self.assertEqual(lc.file_token(SAVED), TOKEN)
        self.assertIsNone(lc.file_token("RookieLedgerDB = {}"))


class Checks(unittest.TestCase):
    def test_own_record(self):
        origin, own = lc.check_db(lc.parse_saved_variables(SAVED))
        self.assertEqual(origin, "0876cf1e")
        self.assertEqual(own["c"]["7421"], [333, 125, 126, 0, 0, 0, 0, 0, 0])
        self.assertEqual(own["s"], {"7421:125:0": [3, 3]})
        self.assertEqual(own["d"]["2584"], {"l": 16, "q": 2, "k": 4, "n": 2, "m": {"10940": [4, 2]}})
        self.assertEqual(own["g"]["1731"], {"k": 1, "n": 4, "m": {"2770": [9, 4], "2835": [1, 1]},
                                            "p": {"1429:432:654": 3, "1429:600:200": 1}})
        self.assertEqual(own["m"]["299"], {"n": 4, "cn": 2, "c": 370, "i": {"2589": [5, 3], "771": [1, 1]}, "p": {}})
        self.assertNotIn("token", json.dumps(own))
        self.assertNotIn("aaaaaaaa", json.dumps(own), "records of other members in the file are not read")

    def test_refuses_a_bad_own_record(self):
        for old, new in (("125, -- [2]", "127, -- [2]"),            # lo above hi
                         ("3, -- [2]\n},\n},\n[\"d\"]", "99, -- [2]\n},\n},\n[\"d\"]"),   # 99 skill-ups from 3 crafts
                         ('["k"] = 4', '["k"] = 3'),                # neither weapon nor armor
                         ("3, -- [1]\n3, -- [2]", '3, -- [1]\n["x"] = 3,'),             # a list with a named field
                         ("4, -- [1]\n2, -- [2]", "400, -- [1]\n2, -- [2]"),              # 200 dust per disenchant
                         ('["id"] = "0876cf1e"', '["id"] = "Some Player"'),
                         ('["1429:432:654"] = 3', '["1429:1432:654"] = 3'),      # a place off the map
                         ('["1429:432:654"] = 3', '["Elwynn:432:654"] = 3'),     # a place that is not numbers
                         ('["1429:432:654"] = 3', '["1429:432:654"] = 5'),       # more gathers there than gathers
                         ('["k"] = 1', '["k"] = 3'),                             # neither vein nor herb
                         ('["cn"] = 2', '["cn"] = 5'),                           # coin known of more corpses than looted
                         ('["c"] = 370', '["c"] = 99999999'),                    # 5000 gold on a corpse
                         ("5, -- [1]\n3, -- [2]", "5, -- [1]\n9, -- [2]"),      # an item in 9 of 4 corpses
                         ('["v"] = 1', '["v"] = 2')):
            self.assertIn(old, SAVED)
            with self.assertRaises(lc.LedgerError, msg=new):
                lc.check_db(lc.parse_saved_variables(SAVED.replace(old, new)))


QUEST_ITEMS = '["own"] = {\n["q"] = {\n["299:2858"] = {\n["q"] = 367,\n["j"] = 1,\n["n"] = 4,\n["k"] = 2,\n["t"] = 3,\n},\n},\n'


class QuestItems(unittest.TestCase):
    def saved(self, old=None, new=None):
        text = SAVED.replace('["own"] = {\n', QUEST_ITEMS, 1)
        self.assertIn('["299:2858"]', text)
        if old:
            self.assertIn(old, text)
            text = text.replace(old, new)
        return lc.check_db(lc.parse_saved_variables(text))[1]

    def test_quest_items_are_kept_and_read(self):
        own = self.saved()
        self.assertEqual(own["q"], {"299:2858": {"q": 367, "j": 1, "n": 4, "k": 2, "t": 3}})
        other = {"q": {"299:2858": {"q": 367, "j": 1, "n": 6, "k": 1, "t": 1}, "300:2859": {"q": 9, "j": 2, "n": 0, "k": 0, "t": 0}}}
        older = {"c": {}, "s": {}}   # a record of a version without quest items
        rates = lc.quest_item_rates({"a": own, "b": other, "c": older})
        self.assertEqual(rates[(299, 2858)], {"quest": 367, "n": 10, "k": 3, "rate": 0.3, "each": 4 / 3})
        self.assertEqual(rates[(300, 2859)], {"quest": 9, "n": 0, "k": 0, "rate": None, "each": None})
        self.assertEqual(lc.check_db(lc.parse_saved_variables(SAVED))[1]["q"], {}, "a file without the section has none")

    def test_the_summary_lists_them(self):
        with tempfile.TemporaryDirectory() as tmp:
            con = lc.connect(Path(tmp) / "ledger.sqlite")
            lc.add_token(con, TOKEN, "A")
            lc.store_upload(con, lc.token_hash(TOKEN), "0876cf1e", self.saved())
            out = io.StringIO()
            ledger_admin.summary(con, out)
            con.close()
        self.assertIn("quest items (1 creature and item pairs)", out.getvalue())
        self.assertIn("creature 299 item 2858 (quest 367): 2/4 = 50%", out.getvalue())

    def test_refuses_bad_quest_items(self):
        for old, new in (('["k"] = 2,\n["t"] = 3', '["k"] = 5,\n["t"] = 5'),      # more drops than chances
                         ('["t"] = 3', '["t"] = 1'),                              # fewer items than drops
                         ('["299:2858"]', '["Sombredogue:2858"]'),               # a key that is not numbers
                         ('["j"] = 1', '["j"] = 0'),
                         ('["q"] = 367', '["q"] = "Une Peste nouvelle"')):       # a quest by its name
            with self.assertRaises(lc.LedgerError, msg=new):
                self.saved(old, new)


class Reading(unittest.TestCase):
    def test_thresholds_rates_and_yields(self):
        _, own = lc.check_db(lc.parse_saved_variables(SAVED))
        other = {"c": {"7421": [333, 0, 0, 131, 140, 0, 0, 0, 0]}, "s": {}}   # a record of an older version
        records = {"0876cf1e": own, "aaaaaaaa": other}
        t = lc.colour_thresholds(records)[7421]
        self.assertEqual(t["ranges"], [(125, 126), (131, 140), None, None])
        self.assertEqual(t["yellow"], (126, 131), "yellow starts above 126 and by 131")
        self.assertIsNone(t["green"])
        self.assertFalse(t["conflict"])
        self.assertEqual(lc.skill_up_rates(records), {(7421, 0): (3, 3)})
        self.assertEqual(lc.disenchant_yields(records), {(2, 4, 16): {"n": 2, "materials": {10940: (2.0, 1.0)}}})
        self.assertEqual(lc.gather_yields(records), {1731: {
            "kind": 1, "n": 4, "materials": {2770: (2.25, 1.0), 2835: (0.25, 0.25)},
            "places": {(1429, 432, 654): 3, (1429, 600, 200): 1}}})
        self.assertEqual(lc.drop_rates(records), {299: {
            "n": 4, "coin": 185.0, "items": {2589: (1.25, 0.75), 771: (0.25, 0.25)}}})

    def test_overlapping_colours_are_a_conflict(self):
        records = {"a": {"c": {"1": [333, 100, 130, 125, 140, 0, 0, 0, 0]}, "s": {}, "d": {}}}
        t = lc.colour_thresholds(records)[1]
        self.assertTrue(t["conflict"])
        self.assertIsNone(t["yellow"])


class Endpoint(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.db = self.dir / "ledger.sqlite"
        # The endpoint's settings for these tests; the module has its own back afterwards.
        for target, name, value in ((ledger_ingest, "TOKEN_CACHE", 0), (ledger_ingest, "MIN_INTERVAL", 0),
                                    (ledger_ingest.Handler, "log_message", lambda *args: None)):
            patch = mock.patch.object(target, name, value)
            patch.start()
            self.addCleanup(patch.stop)
        self.server = ledger_ingest.Server(("127.0.0.1", 0), self.db, getattr(self, "registration", "closed"))
        self.url = "http://127.0.0.1:%d/v1/ledger/" % self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        shutil.rmtree(self.dir)

    def call(self, path, token=TOKEN, body=None, headers=None):
        request = urllib.request.Request(self.url + path, data=body, headers={"Authorization": "Bearer " + token,
                                                                             **(headers or {})})
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            with error:
                return error.code, error.read()

    def raw(self, request):
        """What the endpoint answers to bytes sent as they are, up to the moment it closes the connection."""
        with socket.create_connection(self.server.server_address, timeout=5) as sock:
            sock.sendall(request)
            answer = b""
            try:
                while chunk := sock.recv(65536):
                    answer += chunk
            except OSError:
                answer += b"<no end>"
            return answer

    def register(self, token=TOKEN, label="A"):
        con = lc.connect(self.db)
        lc.add_token(con, token, label)
        con.close()

    def test_health_needs_no_token(self):
        answer = self.raw(b"GET /healthz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        self.assertTrue(answer.startswith(b"HTTP/1.1 200 "), answer)
        self.assertTrue(answer.endswith(b'{"status":"ok","version":"dev"}'), answer)

    def test_sigterm_stops_the_service(self):
        # As the first process of a container would get it: the service ends by itself, well before a kill.
        service = subprocess.Popen([sys.executable, "-I", str(ROOT / "server" / "ledger_ingest.py"), "--host", "127.0.0.1",
                                    "--port", "0", "--db", str(self.dir / "other.sqlite")], stderr=subprocess.PIPE)
        try:
            service.stderr.readline()   # the line it writes once it listens
            service.terminate()
            self.assertEqual(service.wait(timeout=10), 0)
        finally:
            service.kill()
            service.stderr.close()

    def test_unregistered_token_gets_nothing(self):
        self.assertEqual(self.call("status")[0], 401)
        self.assertEqual(self.call("upload", body=SAVED.encode())[0], 401)
        self.assertEqual(self.call("status", token="not a token")[0], 401)
        con = lc.connect(self.db)
        self.assertEqual(con.execute("SELECT count(*) FROM ledger_records").fetchone()[0], 0)
        con.close()

    def test_upload_store_and_repeat(self):
        self.register()
        self.assertEqual(self.call("status")[0], 204)
        status, body = self.call("upload", body=gzip.compress(SAVED.encode()), headers={"Content-Encoding": "gzip"})
        self.assertEqual((status, json.loads(body)),
                         (200, {"id": "0876cf1e", "rev": 7, "stored": 1, "skipped": 0}))
        status, body = self.call("upload", body=SAVED.encode())
        self.assertEqual(json.loads(body)["stored"], 0, "the same file again changes nothing")
        con = lc.connect(self.db)
        self.assertEqual(sorted(lc.current_records(con)), ["0876cf1e"])
        self.assertNotIn(TOKEN, " ".join(map(str, con.execute("SELECT * FROM ledger_tokens").fetchall()
                                             + con.execute("SELECT * FROM ledger_records").fetchall())))
        out = io.StringIO()
        ledger_admin.summary(con, out)
        self.assertIn("recipe 7421: orange 125-126", out.getvalue())
        self.assertIn("recipe 7421 orange: 3/3 = 100%", out.getvalue())
        self.assertIn("item 10940: 2.00 each, in 100%", out.getvalue())
        self.assertIn("vein 1731, 4 gathers at 2 places: item 2770: 2.25 each, in 100%, item 2835: 0.25 each, in 25%",
                      out.getvalue())
        self.assertIn("monster loot (1 kinds of creature, 4 corpses)", out.getvalue())
        self.assertIn("creature 299, 4 corpses, 185 copper each, 2 different items", out.getvalue())
        self.assertIn("quest items (0 creature and item pairs)", out.getvalue())
        con.close()

    def test_a_revoked_token_no_longer_counts(self):
        self.register()
        self.assertEqual(self.call("upload", body=SAVED.encode())[0], 200)
        con = lc.connect(self.db)
        # A copy another member relayed, as versions with guild sync stored them, is not read.
        con.execute("INSERT INTO ledger_records VALUES ('eeeeeeee', ?, 0, 5, 1, 1, 'x', '{}')", (lc.token_hash(TOKEN),))
        con.commit()
        self.assertEqual(sorted(lc.current_records(con)), ["0876cf1e"])
        # Purging those copies leaves every member's own record where it was.
        self.assertEqual(lc.purge_relayed(con), 1)
        self.assertEqual(lc.purge_relayed(con), 0)
        self.assertEqual(con.execute("SELECT origin, own FROM ledger_records").fetchall(), [("0876cf1e", 1)])
        self.assertEqual(sorted(lc.current_records(con)), ["0876cf1e"])
        self.assertEqual(lc.revoke_token(con, "A"), 1)
        self.assertEqual(lc.current_records(con), {})
        con.close()
        self.assertEqual(self.call("status")[0], 401)

    def test_a_token_writes_one_record_id(self):
        self.register()
        self.register(OTHER, "B")
        self.assertEqual(self.call("upload", body=SAVED.encode())[0], 200)
        # B's file names A's id as its own, with a higher counter: refused, A's record is untouched.
        stolen = SAVED.replace('["rev"] = 7', '["rev"] = 900').replace("3, -- [2]\n},\n},\n[\"d\"]", "0, -- [2]\n},\n},\n[\"d\"]")
        self.assertNotEqual(stolen, SAVED)
        status, body = self.call("upload", token=OTHER, body=stolen.encode())
        self.assertEqual(status, 409, body)
        con = lc.connect(self.db)
        self.assertEqual(lc.current_records(con)["0876cf1e"]["s"], {"7421:125:0": [3, 3]})
        # A's token cannot move to another id either, until the keeper lifts the tie.
        moved = SAVED.replace('"0876cf1e"', '"dddddddd"')
        self.assertEqual(self.call("upload", body=moved.encode())[0], 409)
        self.assertEqual(lc.unbind_token(con, "A"), 1)
        con.close()
        self.assertEqual(self.call("upload", body=moved.encode())[0], 200)

    def test_an_oversized_record_is_cut_not_refused(self):
        self.register()
        with mock.patch.object(lc, "MAX_ENTRIES", 2):
            status, body = self.call("upload", body=SAVED.encode())
        self.assertEqual((status, json.loads(body)["skipped"]), (200, 3))
        con = lc.connect(self.db)
        own = lc.current_records(con)["0876cf1e"]
        con.close()
        self.assertEqual((len(own["c"]), len(own["d"]), len(own["g"]), len(own["s"]), len(own["m"])), (1, 1, 0, 0, 0),
                         "colours and disenchants come first")
        with mock.patch.object(lc, "MAX_PLACES", 1), mock.patch.object(lc, "MAX_ITEMS", 1):
            cut = lc.check_db(lc.parse_saved_variables(SAVED))[1]
        self.assertEqual((len(cut["g"]["1731"]["p"]), len(cut["m"]["299"]["i"]), cut["skipped"]), (1, 1, 2))

    def test_refuses_bad_uploads(self):
        self.register()
        self.assertEqual(self.call("upload", body=b"RookieLedgerDB = os.exit()")[0], 400)
        self.assertEqual(self.call("upload", body=b"\x1f\x8b not gzip", headers={"Content-Encoding": "gzip"})[0], 400)
        self.assertEqual(self.call("upload", body=b"x" * (ledger_ingest.MAX_BODY + 1))[0], 413)
        bomb = gzip.compress(b" " * (ledger_ingest.MAX_TEXT + 1))
        self.assertEqual(self.call("upload", body=bomb, headers={"Content-Encoding": "gzip"})[0], 400)
        self.assertEqual(self.call("nothing")[0], 404)

    def test_a_request_is_not_read_past_its_end(self):
        self.register()
        head = b"Host: x\r\nAuthorization: Bearer " + TOKEN.encode() + b"\r\n"
        status = b"GET /v1/ledger/status HTTP/1.1\r\n" + head
        # A status question that carries a body: the body is not answered as a second request.
        second = status + b"\r\n"
        answer = self.raw(status + b"Content-Length: %d\r\n\r\n" % len(second) + second)
        self.assertTrue(answer.startswith(b"HTTP/1.1 204"), answer[:60])
        self.assertEqual(answer.count(b"HTTP/1.1 "), 1, answer)
        self.assertNotIn(b"Content-Length", answer, "a 204 never says its length")
        # An upload whose length int() cannot read, or that does not say where its body ends.
        upload = b"POST /v1/ledger/upload HTTP/1.1\r\n" + head
        for length in (b"Content-Length: \xb2\r\n", b"Content-Length: " + b"9" * 5000 + b"\r\n",
                       b"Content-Length: 5\r\nTransfer-Encoding: chunked\r\n"):
            answer = self.raw(upload + length + b"\r\n")
            self.assertTrue(answer.startswith(b"HTTP/1.1 413"), (length[:40], answer[:60]))

    def test_one_upload_per_interval(self):
        self.register()
        ledger_ingest.MIN_INTERVAL = 60
        self.assertEqual(self.call("upload", body=SAVED.encode())[0], 200)
        self.assertEqual(self.call("upload", body=SAVED.encode())[0], 429)

    def test_one_file_is_parsed_at_a_time(self):
        self.register()
        answers = []
        with self.server.parsing:   # as while another upload is parsed
            upload = threading.Thread(target=lambda: answers.append(self.call("upload", body=SAVED.encode())[0]))
            upload.start()
            upload.join(0.5)
            self.assertEqual(answers, [], "an upload waits for the one being parsed")
        upload.join(10)
        self.assertEqual(answers, [200])


class Hardening(unittest.TestCase):
    def test_upload_times_of_past_tokens_are_forgotten(self):
        tokens = ledger_ingest.Tokens(None, open_to_all=True)
        with mock.patch.object(ledger_ingest, "MIN_INTERVAL", 20), mock.patch("time.monotonic") as now:
            now.return_value = 1000.0
            self.assertTrue(tokens.may_upload("a"))
            now.return_value = 1010.0
            self.assertFalse(tokens.may_upload("a"))
            self.assertTrue(tokens.may_upload("b"))
            now.return_value = 1025.0
            self.assertTrue(tokens.may_upload("c"))
            self.assertEqual(sorted(tokens.last_upload), ["b", "c"], "a's time is past MIN_INTERVAL and forgotten")
            self.assertFalse(tokens.may_upload("b"), "b's is not")

    def test_the_log_writes_no_control_character(self):
        with mock.patch("sys.stderr", new_callable=io.StringIO) as log:
            ledger_ingest.Handler.log_message(None, '"%s" %s %s', "GET /\x1b[2J\rfake\\x0d HTTP/1.1", "404", "-")
        self.assertTrue(log.getvalue().endswith(' "GET /\\x1b[2J\\x0dfake\\\\x0d HTTP/1.1" 404 -\n'), log.getvalue())
        self.assertEqual(log.getvalue().count("\n"), 1)


# SAVED as an addon from v0.6.0 on writes it: begun days ago, two hours of play.
PLAYED = SAVED.replace('["rev"] = 7,', '["rev"] = 7,\n["f"] = 1794700000,\n["a"] = 7200,')
LATER = 49 * 3600   # past the probation of a token that registered itself


class OpenSite(unittest.TestCase):
    """A site where nobody registers tokens by hand: the first upload of a token registers it."""
    registration = "open"
    setUp, tearDown, call, register = Endpoint.setUp, Endpoint.tearDown, Endpoint.call, Endpoint.register

    def labels(self):
        con = lc.connect(self.db)
        try:
            return con.execute("SELECT label, origin, revoked_at IS NULL FROM ledger_tokens ORDER BY label").fetchall()
        finally:
            con.close()

    def test_a_first_upload_registers_its_token(self):
        self.assertEqual(self.call("status")[0], 204)   # what lets the companion app go on to upload
        self.assertEqual(self.labels(), [], "asking registers nothing")
        status, body = self.call("upload", body=PLAYED.encode())
        self.assertEqual((status, json.loads(body)), (200, {"id": "0876cf1e", "rev": 7, "stored": 1, "skipped": 0}))
        self.assertEqual(self.labels(), [("self-0876cf1e", "0876cf1e", 1)])
        con = lc.connect(self.db)
        # Kept, but it counts for nothing until its probation is over.
        self.assertEqual(lc.current_records(con), {})
        self.assertEqual(sorted(lc.current_records(con, time.time() + LATER)), ["0876cf1e"])
        self.assertIn("counts from", lc.digest(con)[0])
        self.assertNotIn(TOKEN, str(con.execute("SELECT * FROM ledger_tokens").fetchall()))
        con.close()
        newer = SAVED.replace('["rev"] = 7', '["rev"] = 8')
        self.assertEqual(json.loads(self.call("upload", body=newer.encode())[1])["stored"], 1)
        self.assertEqual(len(self.labels()), 1)

    def test_the_token_still_ties_a_record_to_who_made_it(self):
        self.assertEqual(self.call("upload", body=PLAYED.encode())[0], 200)
        stolen = PLAYED.replace('["rev"] = 7', '["rev"] = 900')
        status, body = self.call("upload", token=OTHER, body=stolen.encode())
        self.assertEqual(status, 409, body)
        self.assertEqual(len(self.labels()), 1, "a refused upload leaves no token behind")
        con = lc.connect(self.db)
        self.assertEqual(lc.current_records(con, time.time() + LATER)["0876cf1e"]["rev"], 7)
        con.close()
        # The token that failed is not shut out: with a record of its own it registers.
        own = SAVED.replace('"0876cf1e"', '"dddddddd"')
        self.assertEqual(self.call("upload", token=OTHER, body=own.encode())[0], 200)
        self.assertEqual([row[0] for row in self.labels()], ["self-0876cf1e", "self-dddddddd"])

    def test_what_is_refused_registers_nothing(self):
        for token, body in ((TOKEN, b"RookieLedgerDB = os.execute('x')"), (TOKEN, SAVED.replace('["v"] = 1', '["v"] = 2').encode()),
                            ("not a token", SAVED.encode()), (TOKEN.upper(), SAVED.encode())):
            self.assertIn(self.call("upload", token=token, body=body)[0], (400, 401), token)
        self.assertEqual(self.labels(), [])

    def test_a_revoked_token_stays_out(self):
        self.assertEqual(self.call("upload", body=SAVED.encode())[0], 200)
        con = lc.connect(self.db)
        self.assertEqual(lc.revoke_token(con, "0876cf1e"), 1)   # by record id: the keeper never saw the token
        self.assertEqual(lc.current_records(con), {})
        con.close()
        self.assertEqual(self.call("status")[0], 401)
        self.assertEqual(self.call("upload", body=SAVED.replace('["rev"] = 7', '["rev"] = 8').encode())[0], 401)
        self.assertEqual(self.labels(), [("self-0876cf1e", "0876cf1e", 0)])

    def test_new_tokens_are_limited(self):
        with mock.patch.object(ledger_ingest, "MAX_SELF_PER_DAY", 1):
            self.assertEqual(self.call("upload", body=SAVED.encode())[0], 200)
            other = SAVED.replace('"0876cf1e"', '"dddddddd"').encode()
            status, body = self.call("upload", token=OTHER, body=other)
            self.assertEqual(status, 429, body)
            self.assertEqual(len(self.labels()), 1)
            # A token the keeper registers by hand is not held to that number, nor is one already in.
            self.register(OTHER, "B")
            self.assertEqual(self.call("upload", token=OTHER, body=other)[0], 200)
            self.assertEqual(self.call("upload", body=SAVED.replace('["rev"] = 7', '["rev"] = 8').encode())[0], 200)
        with mock.patch.object(ledger_ingest, "MAX_UNKNOWN_PER_MINUTE", 0):
            third = "11112222333344445555666677778888"
            self.assertEqual(self.call("upload", token=third, body=SAVED.replace('"0876cf1e"', '"eeeeeeee"').encode())[0], 429)
            self.assertEqual(self.call("upload", body=SAVED.replace('["rev"] = 7', '["rev"] = 9').encode())[0], 200)

    def test_who_knocks_is_told_what_the_door_is_for(self):
        for path, token in (("upload", "not a token"), ("nowhere", TOKEN)):
            status, body = self.call(path, token=token)
            self.assertIn("does not authorise", json.loads(body)["notice"], path)

    def test_a_site_is_closed_unless_asked(self):
        with self.assertRaises(ValueError):
            ledger_ingest.Server(("127.0.0.1", 0), self.db, "public")
        closed = ledger_ingest.Server(("127.0.0.1", 0), self.db)
        self.addCleanup(closed.server_close)
        self.assertIsNone(closed.tokens.known(OTHER))


class Trust(unittest.TestCase):
    """What a token that registered itself has to show before its record counts."""
    NOW = 1795000000

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir)
        self.con = lc.connect(self.dir / "ledger.sqlite")
        self.addCleanup(self.con.close)

    def record(self, corpses, active, rev=1, began=None):
        return {"rev": rev, "t": self.NOW, "b": 1, "f": self.NOW - 30 * 86400 if began is None else began, "a": active,
                "c": {}, "s": {}, "d": {}, "g": {}, "q": {}, "m": {"299": {"n": corpses, "cn": 0, "c": 0, "i": {}, "p": {}}}}

    def upload(self, record, now, digest="d1", origin="0876cf1e"):
        if not self.con.execute("SELECT 1 FROM ledger_tokens WHERE token_hash = ?", (digest,)).fetchone():
            lc.self_register(self.con, digest, origin, 50)
            self.con.execute("UPDATE ledger_tokens SET added_at = ? WHERE token_hash = ?", (lc.now_iso(now), digest))
        lc.store_upload(self.con, digest, origin, record, now)
        return self.con.execute("SELECT held FROM ledger_tokens WHERE token_hash = ?", (digest,)).fetchone()[0]

    def test_a_first_upload_is_held_to_its_own_account(self):
        week = self.record(9000, 30 * 3600)   # a week of play before finding the app: 300 corpses an hour
        self.assertIsNone(lc.doubt(week, now=self.NOW))
        self.assertIn("things recorded", lc.doubt(self.record(100000, 30 * 3600), now=self.NOW))
        self.assertIn("before its first upload", lc.doubt(self.record(10, 101 * 3600), now=self.NOW))
        self.assertIn("hours of play in", lc.doubt(self.record(10, 30 * 3600, began=self.NOW - 3600), now=self.NOW))
        self.assertIn("before v0.6.0", lc.doubt({**week, "f": 0, "a": 0}, now=self.NOW))
        self.assertEqual(lc.events({**week, "s": {"1:1:0": [5, 2]}, "g": {"1": {"n": 3}}, "d": {"2": {"n": 2}}}), 9010)

    def test_probation_then_it_counts(self):
        self.assertIsNone(self.upload(self.record(9000, 30 * 3600), self.NOW))
        self.assertEqual(lc.current_records(self.con, self.NOW + lc.PROBATION - 60), {})
        self.assertEqual(sorted(lc.current_records(self.con, self.NOW + lc.PROBATION + 60)), ["0876cf1e"])
        # A token the keeper registered is believed at once.
        lc.add_token(self.con, OTHER, "B")
        lc.store_upload(self.con, lc.token_hash(OTHER), "dddddddd", self.record(10**6, 0), self.NOW)
        self.assertEqual(sorted(lc.current_records(self.con, self.NOW)), ["dddddddd"])

    def test_after_the_first_upload_the_site_has_its_own_clock(self):
        self.assertIsNone(self.upload(self.record(1000, 10 * 3600), self.NOW))
        # Two hours later: two more hours of play at most, whatever the file says.
        self.assertIsNone(self.upload(self.record(1500, 12 * 3600, rev=2), self.NOW + 2 * 3600))
        held = self.upload(self.record(1600, 40 * 3600, rev=3), self.NOW + 3 * 3600)
        self.assertIn("hours of play in 1.0 hours", held)
        self.assertEqual(lc.current_records(self.con, self.NOW + 10 * 86400), {})
        # The record is kept all the same, for the keeper to look at, and stays held whatever comes next.
        self.assertEqual(self.con.execute("SELECT rev FROM ledger_records").fetchall(), [(3,)])
        self.assertEqual(self.upload(self.record(1601, 40 * 3600 + 60, rev=4), self.NOW + 4 * 3600), held)
        line, = lc.digest(self.con, now=self.NOW + 10 * 86400)
        self.assertTrue(line.startswith("self-0876cf1e: registered") and "HELD: " + held in line, line)
        self.assertIn("1601 things recorded, 0 places, 40.0 hours of play, 40 an hour", line)
        self.assertEqual(lc.approve_token(self.con, "0876cf1e"), 1)
        self.assertEqual(sorted(lc.current_records(self.con, self.NOW)), ["0876cf1e"])
        self.assertIsNone(self.upload(self.record(10**6, 40 * 3600 + 120, rev=5), self.NOW + 5 * 3600), "approved: believed")

    def test_too_much_too_fast_is_held(self):
        self.assertIsNone(self.upload(self.record(100, 3600), self.NOW))
        self.assertIn("things recorded in 60 minutes", self.upload(self.record(5000, 2 * 3600, rev=2), self.NOW + 86400))
        other = self.upload({**self.record(5, 600), "f": 0, "a": 0}, self.NOW, "d2", "dddddddd")
        self.assertIn("before v0.6.0", other)
        self.assertEqual(len(lc.digest(self.con, now=self.NOW + 30 * 86400)), 2, "held tokens stay in the digest")
        self.assertEqual(lc.revoke_token(self.con, "dddddddd"), 1)
        self.assertEqual(len(lc.digest(self.con, now=self.NOW + 30 * 86400)), 1)

    def test_two_tokens_cannot_tie_one_record_at_once(self):
        lc.add_token(self.con, TOKEN, "A")
        lc.add_token(self.con, OTHER, "B")
        checked, results, real = threading.Event(), {}, lc.now_iso

        def slow(at=None):   # A's upload stops between its checks and its writes, and B's comes in then
            if threading.current_thread().name == "A" and not checked.is_set():
                checked.set()
                time.sleep(0.5)
            return real(at)

        def upload(token):
            con = lc.connect(self.dir / "ledger.sqlite")
            try:
                lc.store_upload(con, lc.token_hash(token), "0876cf1e", self.record(10, 600), self.NOW)
                results[threading.current_thread().name] = "kept"
            except lc.LedgerConflict:
                results[threading.current_thread().name] = "refused"
            finally:
                con.close()

        with mock.patch.object(lc, "now_iso", slow):
            first = threading.Thread(target=upload, args=(TOKEN,), name="A")
            first.start()
            self.assertTrue(checked.wait(10))
            second = threading.Thread(target=upload, args=(OTHER,), name="B")
            second.start()
            first.join(40)
            second.join(40)
        self.assertEqual(results, {"A": "kept", "B": "refused"})
        self.assertEqual(self.con.execute("SELECT label FROM ledger_tokens WHERE origin = '0876cf1e'").fetchall(), [("A",)])

    def test_a_database_of_before_is_brought_up_to_date(self):
        old = self.dir / "old.sqlite"
        con = sqlite3.connect(old)
        con.execute("CREATE TABLE ledger_tokens (token_hash TEXT PRIMARY KEY, label TEXT NOT NULL, added_at TEXT NOT NULL, "
                    "revoked_at TEXT, last_upload TEXT, origin TEXT)")
        con.execute("INSERT INTO ledger_tokens VALUES ('h', 'A', '2026-01-01T00:00:00+00:00', NULL, NULL, NULL)")
        con.commit()
        con.close()
        con = lc.connect(old)
        lc.store_upload(con, "h", "0876cf1e", self.record(10, 0), self.NOW)
        self.assertEqual(sorted(lc.current_records(con, self.NOW)), ["0876cf1e"])
        con.close()


class Package(unittest.TestCase):
    # The packager copies the whole repository into the addon's folder and leaves out only what .pkgmeta ignores
    # (and dotfiles): a new folder at the top goes into the zip unless it is named there.
    def test_pkgmeta_leaves_out_all_but_the_addon(self):
        try:
            run = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True, timeout=60)
        except (OSError, subprocess.CalledProcessError):
            self.skipTest("not a git checkout")
        top = {path.split("/", 1)[0] for path in run.stdout.splitlines() if path}
        ignored, in_ignore = set(), False
        for line in (ROOT / ".pkgmeta").read_text().splitlines():
            if line and not line[0].isspace():
                in_ignore = line.rstrip() == "ignore:"
            elif in_ignore and line.strip().startswith("- "):
                ignored.add(line.strip()[2:].strip())
        shipped = {name for name in top - ignored if not name.startswith(".")}
        self.assertEqual(shipped, {"addon", "LICENSE", "CHANGELOG.md"})


# Skipped only on a developer's machine without lua5.1: in CI a missing lua5.1 is an error, not a green run without
# the addon's tests.
@unittest.skipUnless(shutil.which("lua5.1") or os.environ.get("CI"), "lua5.1 not installed")
class Addon(unittest.TestCase):
    def test_simulated_game_and_its_saved_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "RookieLedger.lua"
            run = subprocess.run(["lua5.1", str(ROOT / "tests" / "rookieledger_harness.lua"),
                                  str(ROOT / "addon" / "RookieLedger"), str(out)], capture_output=True, text=True,
                                 timeout=120)
            self.assertEqual(run.returncode, 0, run.stdout[-2000:] + run.stderr)
            self.assertIn("all checks passed", run.stdout)
            # What the addon saved is what the server accepts.
            origin, own = lc.check_db(lc.parse_saved_variables(out.read_text()))
            self.assertEqual(own["c"]["7421"][0], 333)
            self.assertEqual(own["d"]["2584"]["m"], {"10939": [1, 1], "10940": [2, 1]})
            self.assertEqual(own["s"]["7418:125:1"], [1, 1])
            self.assertEqual(own["g"]["1731"]["m"]["2835"], [1, 1])
            self.assertEqual(own["g"]["1731"]["p"]["1429:600:200"], 1)
            self.assertEqual(own["m"]["299"], {"n": 4, "cn": 4, "c": 370,
                                               "i": {"2589": [5, 3], "771": [1, 1], "4306": [1, 1]},
                                               "p": {"1429:500:500": 4}})
            self.assertEqual((own["m"]["118"]["n"], own["m"]["118"]["cn"], own["m"]["118"]["c"]), (3, 1, 50))
            self.assertEqual(own["q"], {"5000:2858": {"q": 367, "j": 2, "n": 3, "k": 1, "t": 2}})


if __name__ == "__main__":
    unittest.main()
