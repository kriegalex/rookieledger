"""RookieLedger: the addon in a simulated game (lua5.1), the saved-variables parser, the checks and the upload endpoint.
No database of the pipeline is needed; the endpoint runs on a free local port with a temporary database."""
import gzip, io, json, os, shutil, socket, subprocess, sys, tempfile, threading, unittest, urllib.error, urllib.request
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
        self.assertEqual(own["m"]["299"], {"n": 4, "cn": 2, "c": 370, "i": {"2589": [5, 3], "771": [1, 1]}})
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
        self.server = ledger_ingest.Server(("127.0.0.1", 0), self.db)
        self.url = "http://127.0.0.1:%d/api/ledger/v1/" % self.server.server_address[1]
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
        con.close()

    def test_a_revoked_token_no_longer_counts(self):
        self.register()
        self.assertEqual(self.call("upload", body=SAVED.encode())[0], 200)
        con = lc.connect(self.db)
        # A copy another member relayed, as versions with guild sync stored them, is not read.
        con.execute("INSERT INTO ledger_records VALUES ('eeeeeeee', ?, 0, 5, 1, 1, 'x', '{}')", (lc.token_hash(TOKEN),))
        con.commit()
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
        status = b"GET /api/ledger/v1/status HTTP/1.1\r\n" + head
        # A status question that carries a body: the body is not answered as a second request.
        second = status + b"\r\n"
        answer = self.raw(status + b"Content-Length: %d\r\n\r\n" % len(second) + second)
        self.assertTrue(answer.startswith(b"HTTP/1.1 204"), answer[:60])
        self.assertEqual(answer.count(b"HTTP/1.1 "), 1, answer)
        # An upload whose length int() cannot read, or that does not say where its body ends.
        upload = b"POST /api/ledger/v1/upload HTTP/1.1\r\n" + head
        for length in (b"Content-Length: \xb2\r\n", b"Content-Length: " + b"9" * 5000 + b"\r\n",
                       b"Content-Length: 5\r\nTransfer-Encoding: chunked\r\n"):
            answer = self.raw(upload + length + b"\r\n")
            self.assertTrue(answer.startswith(b"HTTP/1.1 413"), (length[:40], answer[:60]))

    def test_one_upload_per_interval(self):
        self.register()
        ledger_ingest.MIN_INTERVAL = 60
        self.assertEqual(self.call("upload", body=SAVED.encode())[0], 200)
        self.assertEqual(self.call("upload", body=SAVED.encode())[0], 429)


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
                                               "i": {"2589": [5, 3], "771": [1, 1], "4306": [1, 1]}})
            self.assertEqual((own["m"]["118"]["n"], own["m"]["118"]["cn"], own["m"]["118"]["c"]), (3, 1, 50))


if __name__ == "__main__":
    unittest.main()
