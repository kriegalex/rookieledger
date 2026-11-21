"""The parts of the map build that need neither the game nor the network: python3 -I -m unittest discover -s tests"""
import struct, sys, tempfile, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).absolute().parent.parent / "tools" / "maps"))
import build_names


def cache_file(creatures):
    """A creature cache as the client writes it, holding {id: name as bytes}."""
    data = b"BOMW" + bytes(20)
    for creature, name in creatures.items():
        record = bytes(build_names.NAME_AT) + name + b"\0" + bytes(40)
        data += struct.pack("<II", creature, len(record)) + record
    return data + bytes(8)


class Names(unittest.TestCase):
    def test_names_are_read_from_the_cache_of_the_install(self):
        with tempfile.TemporaryDirectory() as install:
            folder = Path(install) / "_forever_" / "Cache" / "WDB" / "frFR"
            folder.mkdir(parents=True)
            (folder / "creaturecache.wdb").write_bytes(cache_file({
                1017: "Faucheur des hautes-terres".encode(), 1525: "Squelette pourrissant".encode(),
                7: b"\xff\xfe not text", 8: b"x", 9: b" padded "}))
            self.assertEqual(build_names.creatures(install, "frFR"),
                             {1017: "Faucheur des hautes-terres", 1525: "Squelette pourrissant"})

    def test_the_asker_is_written_with_its_list_and_taken_out_when_the_list_is_empty(self):
        with tempfile.TemporaryDirectory() as install:
            addons = Path(install) / "_forever_" / "Interface" / "AddOns"
            (addons / "RookieLedger").mkdir(parents=True)
            folder = build_names.set_asker(install, [1017, 271334])
            self.assertEqual(folder, addons / "RookieLedgerNames")
            self.assertEqual(sorted(p.name for p in folder.iterdir()), ["Ids.lua", "Names.lua", "RookieLedgerNames.toc"])
            self.assertIn("RookieLedgerNamesIds = { 1017, 271334 }", (folder / "Ids.lua").read_text())
            build_names.set_asker(install, [1017])
            self.assertIn("RookieLedgerNamesIds = { 1017 }", (folder / "Ids.lua").read_text())
            build_names.set_asker(install, [])
            self.assertEqual([p.name for p in addons.iterdir()], ["RookieLedger"])

    def test_nothing_is_removed_where_the_asker_never_was(self):
        with tempfile.TemporaryDirectory() as install:
            folder = Path(install) / "_forever_" / "Interface" / "AddOns" / "RookieLedgerNames"
            folder.mkdir(parents=True)
            (folder / "kept.txt").write_text("someone else's")
            build_names.set_asker(install, [])
            self.assertTrue((folder / "kept.txt").exists())


if __name__ == "__main__":
    unittest.main()
