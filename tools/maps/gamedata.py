"""The game's own tables and textures, as the map build needs them, kept in a cache folder once read. Tables come
from wago.tools, which mirrors what the game client holds. Textures come from a game install when one is given (its
own language's art, and no load on the mirror, which refuses more than a hundred or so downloads in a row), else
from the mirror, in English. Nothing here is from uploads."""
import csv, os, time, urllib.request
from pathlib import Path

BUILD = "1.60.1.70959"          # the Forever client the tables and textures are read from
LOCALE = "frFR"
SOURCE = "https://wago.tools"
AGENT = "rookieledger-map-build/1.0"
PAUSE = 0.05                    # seconds between two downloads: a mirror run by volunteers


class GameData:
    def __init__(self, cache, install=None, build=BUILD, locale=LOCALE, product="wowf"):
        """install: the `World of Warcraft` folder of a client in `locale`, to read textures from."""
        self.cache, self.build, self.locale, self.install = Path(cache), build, locale, None
        self.textures = self.cache / ("blp-" + locale if install else "blp")
        (self.cache / "db2").mkdir(parents=True, exist_ok=True)
        self.textures.mkdir(parents=True, exist_ok=True)
        if install:
            os.environ["OPENMAP_LOCALE"] = locale   # the reader takes its language from there, when it is loaded
            import casc
            self.install = casc.Casc(str(install), product)

    def _get(self, url, path, least):
        if not path.exists() or path.stat().st_size < least:
            request = urllib.request.Request(url, headers={"User-Agent": AGENT})
            with urllib.request.urlopen(request, timeout=120) as response:
                data = response.read()
            # The mirror answers 200 with an empty or tiny body for a file it does not have.
            if len(data) < least:
                raise LookupError(f"{url}: {len(data)} bytes, not a file")
            path.write_bytes(data)
            time.sleep(PAUSE)
        return path

    def table(self, name):
        """The rows of a client table, as dicts of strings."""
        path = self._get(f"{SOURCE}/db2/{name}/csv?build={self.build}&locale={self.locale}",
                         self.cache / "db2" / f"{name}.{self.locale}.csv", 40)
        with open(path, encoding="utf-8", newline="") as f:
            return list(csv.DictReader(f))

    def texture(self, file_id):
        """The path of a texture (BLP), by the client's id of the file. LookupError when there is none."""
        path = self.textures / f"{int(file_id)}.blp"
        if self.install is None:
            return self._get(f"{SOURCE}/api/casc/{int(file_id)}?download&version={self.build}", path, 100)
        if not path.exists():
            try:
                path.write_bytes(self.install.read(int(file_id)))
            except KeyError:
                raise LookupError(f"texture {file_id} is not in the install") from None
        return path
