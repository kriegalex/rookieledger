"""RookieLedger read API: the totals it serves, its paging, its HTTP manners, its key switch, and that every answer
is what its OpenAPI document says. The service runs on a free local port with a temporary database."""
import gzip, io, json, shutil, sys, tempfile, threading, unittest, urllib.error, urllib.request
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).absolute().parent.parent
sys.path.insert(0, str(ROOT / "server"))
import ledger_api, ledger_common as lc

# Two members. Both looted creature 1674 and mined node 1731; only the first disenchanted and crafted.
FIRST = {"rev": 3, "t": 1794800000, "b": 70374,
         "c": {"7421": [333, 125, 126, 0, 0, 0, 0, 0, 0]},
         "s": {"7421:125:0": [4, 6]},
         "d": {"2584": {"l": 16, "q": 2, "k": 4, "n": 2, "m": {"10940": [4, 2]}}},
         "g": {"1731": {"k": 1, "n": 4, "m": {"2770": [9, 4], "2835": [1, 1]}, "p": {"1429:412:655": 3, "1429:500:10": 1}},
               "1617": {"k": 2, "n": 1, "m": {"765": [2, 1]}, "p": {"1437:203:303": 1}}},
         "m": {"1674": {"n": 6, "cn": 4, "c": 40, "i": {"2589": [5, 3]}, "p": {"1429:410:650": 3, "1437:5:1000": 1}},
               "1548": {"n": 2, "cn": 0, "c": 0, "i": {"2672": [2, 2]}}},
         "q": {"1674:2834": {"q": 358, "j": 3, "n": 4, "k": 3, "t": 3}}}
SECOND = {"rev": 1, "t": 1794900000, "b": 70374, "c": {"7421": [333, 0, 0, 140, 150, 0, 0, 0, 0]}, "s": {}, "d": {},
          "g": {"1731": {"k": 1, "n": 2, "m": {"2770": [3, 2]}, "p": {"1429:412:655": 2}}},
          "m": {"1674": {"n": 4, "cn": 4, "c": 20, "i": {"2589": [2, 2], "4604": [1, 1]}, "p": {"1429:410:650": 4}}},
          "q": {"1674:2834": {"q": 358, "j": 3, "n": 3, "k": 2, "t": 2}}}


def as_saved(value):
    """The record as the game's saved file gives it to the checks: whole-number keys, a list as keys 1..n."""
    if isinstance(value, list):
        return {index: part for index, part in enumerate(value, 1)}
    if isinstance(value, dict):
        return {int(key) if key.isdigit() else key: as_saved(part) for key, part in value.items()}
    return value


RECORDS = {"0876cf1e": lc.check_record(as_saved(FIRST)), "1234abcd": lc.check_record(as_saved(SECOND))}


def conforms(value, schema, schemas, where="answer"):
    """Raises AssertionError unless `value` is what `schema` says: the part of JSON Schema the contract uses."""
    if "$ref" in schema:
        return conforms(value, schemas[schema["$ref"].rsplit("/", 1)[1]], schemas, where)
    if "oneOf" in schema:
        for option in schema["oneOf"]:
            try:
                return conforms(value, option, schemas, where)
            except AssertionError:
                pass
        raise AssertionError(f"{where}: {value!r} fits none of the options")
    types = schema.get("type")
    if types:
        names = {"object": dict, "array": list, "string": str, "boolean": bool, "null": type(None)}
        ok = False
        for name in [types] if isinstance(types, str) else types:
            if name == "integer":
                ok |= type(value) is int
            elif name == "number":
                ok |= type(value) in (int, float)
            else:
                ok |= type(value) is names[name]
        assert ok, f"{where}: {value!r} is not {types}"
    if "enum" in schema:
        assert value in schema["enum"], f"{where}: {value!r} is not one of {schema['enum']}"
    if type(value) in (int, float):
        assert schema.get("minimum", value) <= value <= schema.get("maximum", value), f"{where}: {value} out of bounds"
    if isinstance(value, dict):
        properties, extra = schema.get("properties", {}), schema.get("additionalProperties", True)
        for name in schema.get("required", ()):
            assert name in value, f"{where}: {name} is missing"
        for name, part in value.items():
            if name in properties:
                conforms(part, properties[name], schemas, f"{where}.{name}")
            else:
                assert extra is not False, f"{where}: {name} is not in the contract"
                if isinstance(extra, dict):
                    conforms(part, extra, schemas, f"{where}.{name}")
    if isinstance(value, list) and "items" in schema:
        for index, part in enumerate(value):
            conforms(part, schema["items"], schemas, f"{where}[{index}]")


class Totals(unittest.TestCase):
    def setUp(self):
        self.view = ledger_api.View(RECORDS, "2026-11-19T22:00:00+00:00")

    def get(self, path, query=""):
        return ledger_api.answer(self.view, path, query)

    def test_creatures_are_summed_over_the_records(self):
        gnoll = self.get("/creatures/1674")
        self.assertEqual((gnoll["corpses"], gnoll["coin_corpses"], gnoll["coin_total"], gnoll["coin_average"]),
                         (10, 8, 60, 7.5))
        self.assertEqual(gnoll["drops"], [
            {"item": 2589, "times": 5, "quantity": 7, "rate": 0.5, "average_quantity": 1.4},
            {"item": 4604, "times": 1, "quantity": 1, "rate": 0.1, "average_quantity": 1.0}])
        self.assertEqual(gnoll["quest_drops"], [
            {"item": 2834, "quest": 358, "chances": 7, "drops": 5, "quantity": 5, "rate": 0.7143}])
        # A monster whose coin was never seen has no average, not an average of zero.
        self.assertIsNone(self.get("/creatures/1548")["coin_average"])

    def test_an_item_names_everything_that_gave_it(self):
        self.assertEqual(self.get("/items/2589")["dropped_by"],
                         [{"creature": 1674, "corpses": 10, "times": 5, "quantity": 7, "rate": 0.5, "average_quantity": 1.4}])
        self.assertEqual(self.get("/items/2834")["quest_dropped_by"],
                         [{"creature": 1674, "quest": 358, "chances": 7, "drops": 5, "quantity": 5, "rate": 0.7143}])
        self.assertEqual(self.get("/items/2770")["gathered_from"],
                         [{"node": 1731, "kind": "mining", "gathers": 6, "times": 6, "quantity": 12, "rate": 1.0,
                           "average_quantity": 2.0}])
        self.assertEqual(self.get("/items/10940")["disenchanted_from"],
                         [{"quality": "uncommon", "item_class": "armor", "item_level": 16, "disenchants": 2, "times": 2,
                           "quantity": 4, "rate": 1.0, "average_quantity": 2.0}])
        self.assertEqual([row["id"] for row in self.get("/creatures", "item=2834")["data"]], [1674])
        self.assertEqual(self.get("/creatures", "item=99")["data"], [])

    def test_places_are_summed_and_sorted_by_map(self):
        self.assertEqual(self.get("/maps/1429/node-places")["data"], [
            {"node": 1731, "kind": "mining", "map": 1429, "x": 0.412, "y": 0.655, "gathers": 5},
            {"node": 1731, "kind": "mining", "map": 1429, "x": 0.5, "y": 0.01, "gathers": 1}])
        self.assertEqual(self.get("/maps")["data"], [
            {"id": 1429, "nodes": [1731], "node_place_count": 2, "gathers": 6,
             "creatures": [1674], "creature_place_count": 1, "corpses": 7},
            {"id": 1437, "nodes": [1617], "node_place_count": 1, "gathers": 1,
             "creatures": [1674], "creature_place_count": 1, "corpses": 1}])
        self.assertEqual([row["id"] for row in self.get("/nodes", "kind=herbalism")["data"]], [1617])
        self.assertEqual([row["id"] for row in self.get("/nodes", "map=1429")["data"]], [1731])
        self.assertEqual(len(self.get("/nodes/1731/places")["data"]), 2)
        self.assertEqual(self.get("/maps/1429/node-places", "kind=herbalism")["data"], [])

    def test_monsters_are_placed_where_they_were_looted(self):
        self.assertEqual(self.get("/creatures/1674/places")["data"], [
            {"creature": 1674, "map": 1429, "x": 0.41, "y": 0.65, "corpses": 7},
            {"creature": 1674, "map": 1437, "x": 0.005, "y": 1.0, "corpses": 1}])
        self.assertEqual(self.get("/maps/1437/creature-places")["data"],
                         [{"creature": 1674, "map": 1437, "x": 0.005, "y": 1.0, "corpses": 1}])
        self.assertEqual(self.get("/maps/1429/creature-places", "creature=1548")["data"], [])
        self.assertEqual(len(self.get("/creatures/1674/places", "map=1429")["data"]), 1)
        gnoll = self.get("/creatures/1674")
        self.assertEqual((gnoll["place_count"], gnoll["maps"]), (2, [1429, 1437]))
        # A monster of a record from before places were kept is there, with no place.
        hound = self.get("/creatures/1548")
        self.assertEqual((hound["place_count"], hound["maps"], self.get("/creatures/1548/places")["data"]), (0, [], []))
        self.assertEqual([row["id"] for row in self.get("/creatures", "map=1437")["data"]], [1674])
        old = {key: {**rec, "m": {c: {k: v for k, v in e.items() if k != "p"} for c, e in rec["m"].items()}}
               for key, rec in RECORDS.items()}
        self.assertEqual(ledger_api.View(old).creatures[1674]["place_count"], 0)

    def test_recipes_and_disenchants(self):
        recipe = self.get("/recipes/7421")
        self.assertEqual(recipe["seen"]["orange"], {"lowest": 125, "highest": 126})
        self.assertEqual(recipe["turns"], {"yellow": {"after": 126, "by": 140}, "green": None, "grey": None})
        self.assertEqual(recipe["crafts"]["orange"], {"crafts": 4, "skill_ups": 6, "skill_ups_per_craft": 1.5})
        self.assertIsNone(recipe["crafts"]["yellow"])
        self.assertEqual(self.get("/recipes", "profession=1")["data"], [])
        self.assertEqual(len(self.get("/disenchants", "quality=uncommon&item_class=armor&item_level=16")["data"]), 1)
        self.assertEqual(self.get("/disenchants", "quality=epic")["data"], [])

    def test_no_member_can_be_told_from_an_answer(self):
        everything = json.dumps([self.get(path) for path in
                                 ("", "/creatures", "/items", "/nodes", "/maps", "/recipes", "/disenchants",
                                  "/maps/1429/node-places", "/maps/1429/creature-places")])
        for secret in ("0876cf1e", "1234abcd", "1794800000", "1794900000", "70374"):
            self.assertNotIn(secret, everything)
        self.assertEqual(self.get("")["records"], 2)

    def test_pages_follow_a_cursor_to_the_end(self):
        seen, query = [], "limit=1"
        for _ in range(10):
            page = self.get("/items", query)
            seen += [row["id"] for row in page["data"]]
            if not page["next_cursor"]:
                break
            query = "limit=1&cursor=" + page["next_cursor"]
        self.assertEqual(seen, sorted(self.view.items))
        self.assertGreater(len(seen), 4)
        # A cursor names the last row seen: it still works on data that changed, here on an empty database.
        cursor = self.get("/items", "limit=1")["next_cursor"]
        self.assertEqual(ledger_api.answer(ledger_api.View({}), "/items", "cursor=" + cursor),
                         {"data": [], "next_cursor": None})
        places = self.get("/maps/1429/node-places", "limit=1")
        self.assertEqual(len(self.get("/maps/1429/node-places", "cursor=" + places["next_cursor"])["data"]), 1)

    def test_refuses_what_it_does_not_understand(self):
        for path, query, status in (
                ("/creatures", "itme=5", 400), ("/creatures", "item=abc", 400), ("/creatures", "item=1&item=2", 400),
                ("/creatures", "limit=0", 400), ("/creatures", "limit=1001", 400), ("/creatures", "cursor=%%%", 400),
                ("/creatures", "cursor=eyJhIjoxfQ", 400), ("/nodes", "kind=fishing", 400), ("/creatures/1674", "limit=5", 400),
                ("/creatures/9", "", 404), ("/creatures/1674/drops", "", 404), ("/creatures/abc", "", 404),
                ("/maps/7/node-places", "", 404), ("/maps/1429/places", "", 404), ("/nowhere", "", 404)):
            with self.assertRaises(ledger_api.ApiError, msg=path + "?" + query) as caught:
                self.get(path, query)
            self.assertEqual(caught.exception.status, status, path + "?" + query)


class Contract(unittest.TestCase):
    def test_every_answer_is_what_the_document_says(self):
        view, spec = ledger_api.View(RECORDS), ledger_api.openapi()
        schemas = spec["components"]["schemas"]
        self.assertEqual(set(spec["paths"]), {"/", "/openapi.json"} | {route[0] for route in ledger_api.ROUTES})
        ids = {"creature": 1674, "item": 2589, "node": 1731, "map": 1429, "recipe": 7421}
        for path, operation in spec["paths"].items():
            for name in ids:
                path = path.replace("{%s}" % name, str(ids[name]))
            document = ledger_api.answer(view, "" if path == "/" else path, "")
            schema = operation["get"]["responses"]["200"]["content"]["application/json"]["schema"]
            conforms(document, schema, schemas, path)
            if "data" in schema.get("properties", {}):
                self.assertTrue(document["data"], path + " is checked on no row")
            for parameter in operation["get"]["parameters"]:
                self.assertIn("schema", parameter)

    def test_a_field_outside_the_contract_is_caught(self):
        schemas = ledger_api.SCHEMAS
        with self.assertRaises(AssertionError):
            conforms({**ledger_api.View(RECORDS).maps[1429], "who": "0876cf1e"}, schemas["Map"], schemas)


class Service(unittest.TestCase):
    auth = "none"

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.db = self.dir / "ledger.sqlite"
        for target, name, value in ((ledger_api, "REFRESH", -1), (ledger_api.Handler, "log_message", lambda *args: None)):
            patch = mock.patch.object(target, name, value)
            patch.start()
            self.addCleanup(patch.stop)
        self.server = ledger_api.Server(("127.0.0.1", 0), self.db, auth=self.auth)
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        shutil.rmtree(self.dir)

    def upload(self, origin="0876cf1e", record=FIRST, token="0123456789abcdef0123456789abcdef"):
        con = lc.connect(self.db)
        lc.add_token(con, token, origin)
        lc.store_upload(con, lc.token_hash(token), origin, lc.check_record(as_saved(record)))
        con.close()

    def call(self, path, method="GET", headers=None):
        request = urllib.request.Request(self.url + path, method=method, headers=headers or {})
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, dict(response.headers), response.read()
        except urllib.error.HTTPError as error:
            with error:
                return error.code, dict(error.headers), error.read()


class Http(Service):
    def test_answers_before_and_after_the_first_upload(self):
        status, headers, body = self.call("/v1")
        self.assertEqual((status, json.loads(body)["records"]), (200, 0))   # no database file yet
        self.assertEqual(self.call("/v1/creatures")[2], b'{"data":[],"next_cursor":null}')
        self.upload()
        self.assertEqual(json.loads(self.call("/v1")[2])["counts"]["creatures"], 2)
        self.upload("1234abcd", SECOND, "fedcba9876543210fedcba9876543210")
        root = json.loads(self.call("/v1")[2])
        self.assertEqual((root["records"], root["links"]["maps"]), (2, "/v1/maps"))
        self.assertEqual(json.loads(self.call("/v1/creatures/1674")[2])["corpses"], 10)
        # A revoked member's record leaves the totals.
        con = lc.connect(self.db)
        lc.revoke_token(con, "1234abcd")
        con.close()
        self.assertEqual(json.loads(self.call("/v1/creatures/1674")[2])["corpses"], 6)

    def test_records_are_read_again_only_after_a_change(self):
        self.upload()
        with mock.patch.object(lc, "current_records", wraps=lc.current_records) as read:
            for _ in range(3):   # REFRESH is -1 here: every request looks at the database
                self.assertEqual(self.call("/v1/creatures")[0], 200)
            self.assertEqual(read.call_count, 1)
            self.upload("1234abcd", SECOND, "fedcba9876543210fedcba9876543210")
            self.assertEqual(json.loads(self.call("/v1/creatures/1674")[2])["corpses"], 10)
            self.assertEqual(read.call_count, 2)

    def test_caching_compression_and_origins(self):
        self.upload()
        status, headers, body = self.call("/v1/creatures")
        self.assertEqual((status, headers["Content-Type"], headers["Cache-Control"]),
                         (200, "application/json", "public, max-age=60"))
        self.assertEqual((headers["Access-Control-Allow-Origin"], headers["Vary"]), ("*", "Accept-Encoding"))
        etag = headers["ETag"]
        status, headers, again = self.call("/v1/creatures", headers={"If-None-Match": 'W/"other", ' + etag})
        self.assertEqual((status, again, headers["ETag"]), (304, b"", etag))
        status, headers, packed = self.call("/v1/creatures", headers={"Accept-Encoding": "br, gzip"})
        self.assertEqual((headers["Content-Encoding"], gzip.decompress(packed), headers["ETag"]), ("gzip", body, etag))
        self.assertNotIn("Content-Encoding", self.call("/v1/creatures", headers={"Accept-Encoding": "gzip;q=0"})[1])
        status, headers, nothing = self.call("/v1/creatures", "HEAD")
        self.assertEqual((status, nothing, headers["Content-Length"]), (200, b"", str(len(body))))
        # New data, new ETag: the old one no longer answers 304.
        self.upload("1234abcd", SECOND, "fedcba9876543210fedcba9876543210")
        self.assertEqual(self.call("/v1/creatures", headers={"If-None-Match": etag})[0], 200)
        status, headers, _ = self.call("/v1/creatures", "OPTIONS",
                                       {"Origin": "https://example.org", "Access-Control-Request-Method": "GET"})
        self.assertEqual((status, headers["Access-Control-Allow-Methods"]), (204, "GET, HEAD, OPTIONS"))
        self.assertNotIn("Content-Length", headers, "a 204 never says its length")

    def test_an_answer_does_not_need_the_cache_to_keep_it(self):
        class Forgetful(dict):   # emptied as soon as an answer is put in it, as another request's thread may do
            def __setitem__(self, key, value):
                super().__setitem__(key, value)
                self.clear()

        self.upload()
        self.assertEqual(self.call("/v1")[0], 200)
        self.server.store.current().cache = Forgetful()
        status, _, body = self.call("/v1/creatures/1674")
        self.assertEqual((status, json.loads(body)["corpses"]), (200, 6))

    def test_errors_are_problem_documents(self):
        for path, method, status in (("/v1/creatures/9", "GET", 404), ("/v1/creatures?itme=1", "GET", 400),
                                     ("/elsewhere", "GET", 404), ("/v1x", "GET", 404), ("/v1/creatures", "POST", 405),
                                     ("/v1/creatures", "DELETE", 405)):
            got, headers, body = self.call(path, method)
            problem = json.loads(body)
            self.assertEqual((got, headers["Content-Type"], problem["status"], headers["Cache-Control"]),
                             (status, "application/problem+json", status, "no-store"), path)
            self.assertTrue(problem["title"] and problem["detail"] and problem["type"])
        self.assertEqual(self.call("/v1/creatures", "POST")[1]["Allow"], "GET, HEAD, OPTIONS")
        self.assertEqual(self.call("/healthz")[::2], (200, b'{"status":"ok"}'))

    def test_answers_kept_ready_stay_within_their_budget(self):
        self.upload()
        page = self.call("/v1/creatures?limit=1000")[2]
        budget = 3 * len(page)
        with mock.patch.object(ledger_api, "MAX_CACHED_BYTES", budget):
            # One query spelt five ways is five answers to keep.
            for spelling in ("limit=1000", "limit=01000", "limit=001000", "%6Cimit=1000", "limit=%31000"):
                self.assertEqual(self.call("/v1/creatures?" + spelling)[2], page, spelling)
                view = self.server.store.view
                kept = sum(len(raw) + len(packed) for raw, packed, _etag in view.cache.values())
                self.assertEqual(view.cached_bytes, kept)
                self.assertLessEqual(kept, budget)
            self.assertLess(len(view.cache), 5)

    def test_the_document_is_served_and_asks_for_no_key(self):
        spec = json.loads(self.call("/v1/openapi.json")[2])
        self.assertEqual((spec["openapi"], spec["security"], spec["servers"]), ("3.1.0", [], [{"url": "/v1"}]))
        self.assertNotIn("401", spec["paths"]["/creatures"]["get"]["responses"])


class Keys(Service):
    auth = "key"

    def test_only_a_key_that_is_valid_now_reads(self):
        self.upload()
        status, headers, body = self.call("/v1/creatures")
        self.assertEqual((status, headers["WWW-Authenticate"], headers["Content-Type"]),
                         (401, 'Bearer realm="rookieledger"', "application/problem+json"))
        self.assertNotIn(b"1674", body)
        con = lc.connect(self.db)
        key = lc.add_api_key(con, "map page")
        self.assertTrue(key.startswith("rl_"))
        self.assertNotIn(key, str(con.execute("SELECT * FROM api_keys").fetchall()))   # only its hash is kept
        status, headers, body = self.call("/v1/creatures", headers={"Authorization": "Bearer " + key})
        self.assertEqual((status, headers["Cache-Control"], headers["Vary"]),
                         (200, "private, max-age=60", "Accept-Encoding, Authorization"))
        self.assertIn(b"1674", body)
        for wrong in ("Bearer " + key[:-1], "Basic " + key, key, "Bearer"):
            self.assertEqual(self.call("/v1/creatures", headers={"Authorization": wrong})[0], 401, wrong)
        # An upload token is not a key of the read API.
        self.assertEqual(self.call("/v1", headers={"Authorization": "Bearer 0123456789abcdef0123456789abcdef"})[0], 401)
        self.assertEqual(lc.revoke_api_key(con, "map page"), 1)
        con.close()
        self.assertEqual(self.call("/v1/creatures", headers={"Authorization": "Bearer " + key})[0], 401)

    def test_what_stays_open(self):
        self.assertEqual(self.call("/healthz")[0], 200)
        status, _, body = self.call("/v1/openapi.json")
        spec = json.loads(body)
        self.assertEqual((status, spec["security"]), (200, [{"key": []}]))
        self.assertEqual(spec["paths"]["/openapi.json"]["get"]["security"], [])
        self.assertIn("401", spec["paths"]["/creatures"]["get"]["responses"])
        self.assertEqual(self.call("/v1/creatures", "OPTIONS")[0], 204)   # a browser's preflight carries no key

    def test_the_switch_takes_two_values(self):
        with self.assertRaises(ValueError):
            ledger_api.Server(("127.0.0.1", 0), self.db, auth="jwt")


del Service   # the base class has no test of its own


class Log(unittest.TestCase):
    def test_the_log_writes_no_control_character(self):
        with mock.patch("sys.stderr", new_callable=io.StringIO) as log:
            ledger_api.Handler.log_message(None, '"%s" %s %s', "GET /v1/\x1b[2J\rfake HTTP/1.1", "404", "-")
        self.assertTrue(log.getvalue().endswith(' "GET /v1/\\x1b[2J\\x0dfake HTTP/1.1" 404 -\n'), log.getvalue())


if __name__ == "__main__":
    unittest.main()
