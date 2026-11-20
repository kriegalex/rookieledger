#!/usr/bin/env python3
"""Builds the map page's picture of the world from the game's own maps.

  python3 tools/maps/build_world.py <cache folder> <output folder> [--install <World of Warcraft folder>] [--preview]

The game has no seamless map. It has a picture of the world, one of each continent and one per zone, each a
rectangle of the one above it. This puts them all on one canvas, the world's, where the game's tables say they are:

- far out, the world's own picture, with each continent's picture laid over its land;
- close in, every zone's picture, fully explored, over that. A zone's picture also draws what lies round the zone,
  as bare paper or with a neighbour's name on it. So where several zones draw the same place, the one whose own
  land it is has it: a zone's own land is what its explored pieces cover. Elsewhere each counts for as much as the
  place is deep inside its picture, so that one hands over to the next without a line. A city's map is not laid
  over its zone's: it is another kind of drawing;
- in between, a mix of the two, so that zooming in dissolves the world's map into the zones';
- closest of all, one zoom further than the zones' pictures hold, the game's minimap over the zones' own land: the
  ground as the game shows it from above, which is where the detail of a close view comes from.

The result is cut into the tiles a web map loads (tiles/<zoom>/<x>/<y>.webp). world.json says where things are: the
canvas's size and, per continent and zone, its name and its box on the canvas, which is what turns a place of the
API (a zone and a position in it) into a point of the world. The closest zoom has tiles only where there is land:
world.json lists them (`deep`).

Needs Pillow and numpy. The art is Blizzard's; this only arranges it.
"""
import argparse, json, struct, sys
from functools import lru_cache
from pathlib import Path
import numpy as np
from PIL import Image, ImageChops, ImageFilter
sys.path.insert(0, str(Path(__file__).absolute().parent))
from gamedata import GameData

AZEROTH = 947                       # the world's map of the interface
CONTINENTS = {1414: 1, 1415: 0}     # a continent's map of the interface -> the game's id of its world
ZONE = "3"                          # UiMap.Type
SCALE = 0.22                        # pixels per game yard at the closest zoom: about what a zone's picture holds
TILE = 256                          # of the tiles this writes
GRID = 256                          # of the tiles the game's pictures are made of
ZONE_EDGE = 0.16                    # of a zone picture's shorter side: how deep inside it counts in full
ZONE_POWER = 3                      # how fast it loses to a neighbour towards its edge
CONTINENT_EDGE = 0.12               # the same for a continent's picture over the world's
FRAME = 0.05                        # of a continent's picture, at each side: its parchment frame
BLUR = 16                           # pixels: how far out of focus the far picture is under the zones
GRAIN = 7                           # of 255: how strong the paper's grain over it is
STROKE = 13                         # pixels of a world's or continent's picture: strokes thinner than this are lettering
OTHERS = 0.02                       # how much a zone's picture counts outside the zone's own land, of what it counts on it
SHORE = 9                           # pixels of a zone's picture: how far past its explored pieces its own land goes
CITY = 0.35                         # a map inside another and smaller than this share of it is a city's
ADT = 1600 / 3                      # yards: the side of a square of the game's terrain, which is one minimap tile
MINIMAP = 0.9                       # how much the minimap covers the zones' pictures at the closest zoom, on land
FAR, NEAR = 1300, 4000              # canvas widths in pixels: at FAR or less the world's map alone, from NEAR on
                                    # the zones in full
BAND = 512                          # rows composed at once
QUALITY = 82


def region(row):
    """(min x, min y, max x, max y) in game yards. In the game x grows to the north and y to the west."""
    return tuple(float(row[f"Region_{i}"]) for i in (0, 1, 3, 4))


class World:
    def __init__(self, data):
        self.data = data
        self.maps = {int(r["ID"]): r for r in data.table("UiMap")}
        self.assignments = data.table("UiMapAssignment")
        self.art = {int(r["UiMapID"]): int(r["UiMapArtID"]) for r in data.table("UiMapXMapArt") if r["PhaseID"] == "0"}
        styles = {r["UiMapArtStyleID"]: r for r in data.table("UiMapArtStyleLayer") if r["LayerIndex"] == "0"}
        self.layers = {int(r["ID"]): styles.get(r["UiMapArtStyleID"]) for r in data.table("UiMapArt")}
        self.tiles, self.overlays, self.overlay_tiles = {}, {}, {}
        for r in data.table("UiMapArtTile"):
            if r["LayerIndex"] == "0":
                self.tiles.setdefault(int(r["UiMapArtID"]), []).append(r)
        for r in data.table("WorldMapOverlay"):
            self.overlays.setdefault(int(r["UiMapArtID"]), []).append(r)
        for r in data.table("WorldMapOverlayTile"):
            self.overlay_tiles.setdefault(r["WorldMapOverlayID"], []).append(r)
        # Where each continent lies on the world's map: the part of that map it takes (left, top, right, bottom, as
        # shares of it) and the yards of the continent that part shows.
        self.on_world = {}
        for row in self.assignments:
            if int(row["UiMapID"]) == AZEROTH:
                self.on_world[int(row["MapID"])] = (tuple(float(row[k]) for k in ("UiMin_0", "UiMin_1", "UiMax_0", "UiMax_1")),
                                                    region(row))
        yards = [(r[3] - r[1]) / (ui[2] - ui[0]) for ui, r in self.on_world.values()]
        self.width = round(sum(yards) / len(yards) * SCALE)      # the continents agree on the world's width in yards
        layer = self.layers[self.art[AZEROTH]]
        self.height = round(self.width * int(layer["LayerHeight"]) / int(layer["LayerWidth"]))

    def rect(self, ui_map, game_world):
        """Where the whole of a map of the interface lies in a world of the game, in yards, or None."""
        for row in self.assignments:
            if int(row["UiMapID"]) == ui_map and int(row["MapID"]) == game_world and \
                    (float(row["UiMin_0"]), float(row["UiMin_1"]), float(row["UiMax_0"]), float(row["UiMax_1"])) == (0, 0, 1, 1):
                return region(row)

    def box(self, game_world, rect):
        """(left, top, right, bottom) on the canvas, in pixels, of a rectangle of a world of the game in yards."""
        (u0, v0, u1, v1), (min_x, min_y, max_x, max_y) = self.on_world[game_world]
        x0, y0, x1, y1 = rect
        across = lambda y: (u0 + (max_y - y) / (max_y - min_y) * (u1 - u0)) * self.width
        down = lambda x: (v0 + (max_x - x) / (max_x - min_x) * (v1 - v0)) * self.height
        return across(y1), down(x1), across(y0), down(x0)

    def yards(self, game_world, px, py):
        """The place of a world of the game, (x, y) in yards, that a pixel of the canvas shows: `box` backwards."""
        (u0, v0, u1, v1), (min_x, min_y, max_x, max_y) = self.on_world[game_world]
        return (max_x - (py / self.height - v0) / (v1 - v0) * (max_x - min_x),
                max_y - (px / self.width - u0) / (u1 - u0) * (max_y - min_y))

    def minimap(self, game_world):
        """{(column, row): file id} of the minimap tiles of a world of the game, as its own description (WDT) lists
        them: column c covers y from (32 - c) * ADT yards down, row r covers x from (32 - r) * ADT down."""
        row = next(r for r in self.data.table("Map") if int(r["ID"]) == game_world)
        data, at, chunks = self.data.texture(row["WdtFileDataID"]).read_bytes(), 0, {}
        while at + 8 <= len(data):
            size = struct.unpack_from("<I", data, at + 4)[0]
            chunks[data[at:at + 4][::-1]] = data[at + 8:at + 8 + size]
            at += 8 + size
        tiles = {}
        for n in range(64 * 64):
            # MAIN says which squares have terrain; MAID names each one's files, the minimap's last of eight.
            if struct.unpack_from("<I", chunks[b"MAIN"], n * 8)[0] & 1:
                file_id = struct.unpack_from("<8I", chunks[b"MAID"], n * 32)[7]
                if file_id:
                    tiles[(n % 64, n // 64)] = file_id
        return tiles

    def zones(self, continent):
        return sorted(ui_map for ui_map, r in self.maps.items()
                      if r["Type"] == ZONE and int(r["ParentUiMapID"]) == continent
                      and self.rect(ui_map, CONTINENTS[continent]) and ui_map in self.art)

    def _paste(self, into, rows, width, height, at=(0, 0)):
        # Tiles lie on a grid of GRID pixels; the last of a row or column is only as large as what is left of the
        # picture, rounded up to a power of two, so its own size says nothing of where it goes.
        piece = Image.new("RGBA", (width, height))
        for r in rows:
            tile = Image.open(self.data.texture(r["FileDataID"])).convert("RGBA")
            piece.paste(tile, (int(r["ColIndex"]) * GRID, int(r["RowIndex"]) * GRID))
        into.alpha_composite(piece, at)
        return piece

    def picture(self, ui_map, with_land=False):
        """The map of the interface as the game draws it once every part of it is explored. with_land: also, as a
        second value, the zone's own land in it (0 to 255 per pixel): what its explored pieces cover."""
        art = self.art[ui_map]
        layer = self.layers[art]
        width, height = int(layer["LayerWidth"]), int(layer["LayerHeight"])
        image, land = Image.new("RGBA", (width, height)), Image.new("L", (width, height))
        self._paste(image, self.tiles[art], width, height)
        for overlay in self.overlays.get(art, ()):
            rows = self.overlay_tiles.get(overlay["ID"])
            w, h = int(overlay["TextureWidth"]), int(overlay["TextureHeight"])
            if rows and w and h:
                at = (int(overlay["OffsetX"]), int(overlay["OffsetY"]))
                piece = self._paste(image, rows, w, h, at)
                land.paste(ImageChops.lighter(land.crop((at[0], at[1], at[0] + w, at[1] + h)), piece.getchannel("A")), at)
        return (image.convert("RGB"), land) if with_land else image.convert("RGB")

    def inner(self, zone, others):
        """Whether a zone's map lies inside another's and is much smaller: a city's."""
        x0, y0, x1, y1 = others[zone]
        for other, (a0, b0, a1, b1) in others.items():
            if other != zone and a0 <= x0 and b0 <= y0 and a1 >= x1 and b1 >= y1 \
                    and (x1 - x0) * (y1 - y0) < CITY * (a1 - a0) * (b1 - b0):
                return True
        return False


def depth(width, height, edge, power, inside=None):
    """How much each pixel of a picture counts, 0 to 1: nothing at its edge, in full from `edge` of its shorter side
    inwards. `inside`: (left, top, right, bottom) as shares of the picture, when only that part of it is wanted."""
    left, top, right, bottom = inside or (0, 0, 1, 1)
    xs, ys = (np.arange(width) + 0.5) / width, (np.arange(height) + 0.5) / height
    reach = edge * min((right - left) * width, (bottom - top) * height)
    across = np.clip(np.minimum(xs - left, right - xs) * width / reach, 0, 1)
    down = np.clip(np.minimum(ys - top, bottom - ys) * height / reach, 0, 1)
    d = np.minimum.outer(down, across)
    d = d * d * (3 - 2 * d)                 # eased at both ends
    return (d ** power).astype(np.float32)


class Layer:
    """A picture laid on the canvas at a box, with how far each of its pixels covers what is under it (`cover`) and
    how much it counts against other layers at the same place (`weight`)."""

    def __init__(self, picture, box, edge, power, inside=None, land=None):
        self.left, self.top = round(box[0]), round(box[1])
        size = (max(1, round(box[2]) - self.left), max(1, round(box[3]) - self.top))
        self.pixels = np.asarray(picture.resize(size, Image.Resampling.LANCZOS), np.float32)
        self.cover = depth(size[0], size[1], edge, 1, inside)
        self.weight = self.cover ** power
        if land is not None:
            # Its own land, a little past its shore and soft at the edge; the rest of the picture counts for little.
            own = land.filter(ImageFilter.MaxFilter(SHORE)).filter(ImageFilter.GaussianBlur(SHORE)).resize(
                size, Image.Resampling.BILINEAR)
            self.own = np.asarray(own, np.float32) / 255
            self.weight = self.weight * (OTHERS + (1 - OTHERS) * self.own)

    own = None

    def onto(self, colour, weight, cover, land, top):
        """Adds the rows of this layer that fall in a band of the canvas starting at row `top`."""
        rows, width = colour.shape[0], colour.shape[1]
        y0, y1 = max(self.top, top), min(self.top + self.pixels.shape[0], top + rows)
        x0, x1 = max(self.left, 0), min(self.left + self.pixels.shape[1], width)
        if y0 >= y1 or x0 >= x1:
            return
        mine = (slice(y0 - self.top, y1 - self.top), slice(x0 - self.left, x1 - self.left))
        theirs = (slice(y0 - top, y1 - top), slice(x0, x1))
        colour[theirs] += self.pixels[mine] * self.weight[mine][..., None]
        weight[theirs] += self.weight[mine]
        cover[theirs] += self.cover[mine]
        if self.own is not None:
            land[theirs] = np.maximum(land[theirs], self.own[mine] * np.minimum(1, self.cover[mine] * 4))


def shared(base, layers):
    """(`base` with the layers over it, the layers' own land on the canvas). Where several layers cover a pixel, each
    is there for its share of their weights together; the base shows through as far as their covers do not add up
    to one."""
    out = np.asarray(base, np.float32).copy()
    lands = np.zeros(out.shape[:2], np.float32)
    for top in range(0, out.shape[0], BAND):
        band = out[top:top + BAND]
        colour, weight, cover = np.zeros_like(band), np.zeros(band.shape[:2], np.float32), np.zeros(band.shape[:2], np.float32)
        for layer in layers:
            layer.onto(colour, weight, cover, lands[top:top + BAND], top)
        cover = np.clip(cover, 0, 1)[..., None]
        band[:] = band * (1 - cover) + colour / np.maximum(weight, 1e-9)[..., None] * cover
    return (Image.fromarray(np.clip(out + 0.5, 0, 255).astype(np.uint8), "RGB"),
            Image.fromarray(np.clip(lands * 255 + 0.5, 0, 255).astype(np.uint8), "L"))


def unlettered(picture):
    """The picture without its thin dark strokes: the large lettering of the world's and the continents' maps, which
    under the zones would show cut off wherever a zone ends. Its coasts lose their hatching with it."""
    return picture.filter(ImageFilter.MaxFilter(STROKE)).filter(ImageFilter.MinFilter(STROKE))


def grained(picture):
    """The picture with a paper's grain over it, in two sizes: what is out of focus then reads as paper seen close,
    not as a picture enlarged. The same grain at every build."""
    random = np.random.default_rng(947)
    width, height = picture.size
    fine = random.normal(0, GRAIN, (height, width)).astype(np.float32)
    coarse = Image.fromarray(random.normal(0, GRAIN, (height // 4 + 1, width // 4 + 1)).astype(np.float32), "F")
    coarse = np.asarray(coarse.resize((width, height), Image.Resampling.BICUBIC), np.float32)
    out = np.asarray(picture, np.float32) + (fine * 0.6 + coarse)[..., None]
    return Image.fromarray(np.clip(out + 0.5, 0, 255).astype(np.uint8), "RGB")


def pictures(world):
    """(the world from far, the world from near, the zones' own land on it, {continent: box}, {zone: (continent, box)})."""
    size = (world.width, world.height)
    far_layers, plain_layers, near_layers, continents, zones = [], [], [], {}, {}
    for continent, game_world in CONTINENTS.items():
        extent = world.rect(continent, game_world)
        box = world.box(game_world, extent)
        continents[continent] = land = world.box(game_world, world.on_world[game_world][1])
        # Of the continent's picture, only the part the world's map gives it (the rest is sea drawn twice), and
        # never its frame, which the world's map has around itself already.
        inside = (max(FRAME, (land[0] - box[0]) / (box[2] - box[0])), max(FRAME, (land[1] - box[1]) / (box[3] - box[1])),
                  min(1 - FRAME, (land[2] - box[0]) / (box[2] - box[0])), min(1 - FRAME, (land[3] - box[1]) / (box[3] - box[1])))
        far_layers.append(Layer(world.picture(continent), box, CONTINENT_EDGE, 1, inside))
        plain_layers.append(Layer(unlettered(world.picture(continent)), box, CONTINENT_EDGE, 1, inside))
        rects = {zone: world.rect(zone, game_world) for zone in world.zones(continent)}
        for zone, rect in rects.items():
            zone_box = world.box(game_world, rect)
            zones[zone] = (continent, zone_box)
            if not world.inner(zone, rects):
                picture, land = world.picture(zone, with_land=True)
                near_layers.append(Layer(picture, zone_box, ZONE_EDGE, ZONE_POWER, land=land))
    lanczos = Image.Resampling.LANCZOS
    far = shared(world.picture(AZEROTH).resize(size, lanczos), far_layers)[0]
    # Under the zones, the same without its lettering, out of focus and with a paper's grain: between two zones its
    # colours carry on, land as land and sea as sea.
    plain = shared(unlettered(world.picture(AZEROTH)).resize(size, lanczos), plain_layers)[0]
    near, land = shared(grained(plain.filter(ImageFilter.GaussianBlur(BLUR))), near_layers)
    return far, near, land, continents, zones


def cut_deep(world, near, land, folder, zoom):
    """Writes the tiles of one zoom past the canvas, where there is land: the zones' pictures enlarged, with the
    game's minimap over the zones' own land. Returns the tiles written, as "x/y"."""
    minimaps = {game_world: world.minimap(game_world) for game_world in CONTINENTS.values()}
    half = TILE // 2                          # pixels of the canvas one of these tiles shows

    @lru_cache(maxsize=64)
    def ground(file_id):
        try:
            return Image.open(world.data.texture(file_id)).convert("RGB")
        except LookupError:
            return None

    written = []
    for left in range(0, near.width, half):
        for top in range(0, near.height, half):
            box = (left, top, min(left + half, near.width), min(top + half, near.height))
            own = land.crop(box)
            if own.getextrema()[1] < 8:
                continue
            width, height = (box[2] - left) * 2, (box[3] - top) * 2
            mini, there = Image.new("RGB", (width, height)), Image.new("L", (width, height))
            for game_world, squares in minimaps.items():
                north, west = world.yards(game_world, left, top)
                south, east = world.yards(game_world, box[2], box[3])
                across, down = width / (west - east), height / (north - south)       # pixels per yard
                for column in range(int(32 - west / ADT), int(32 - east / ADT) + 1):
                    for row in range(int(32 - north / ADT), int(32 - south / ADT) + 1):
                        picture = ground(squares.get((column, row), 0)) if (column, row) in squares else None
                        if picture is None:
                            continue
                        # Edges rounded one by one, so that two squares side by side share theirs.
                        x0, x1 = round((west - (32 - column) * ADT) * across), round((west - (31 - column) * ADT) * across)
                        y0, y1 = round((north - (32 - row) * ADT) * down), round((north - (31 - row) * ADT) * down)
                        if x1 > x0 and y1 > y0:
                            mini.paste(picture.resize((x1 - x0, y1 - y0), Image.Resampling.LANCZOS), (x0, y0))
                            there.paste(255, (x0, y0, x1, y1))
            base = near.crop(box).resize((width, height), Image.Resampling.BICUBIC)
            mask = ImageChops.multiply(own.resize((width, height), Image.Resampling.BICUBIC), there).point(lambda v: v * MINIMAP)
            tile = Image.new("RGB", (TILE, TILE), (29, 24, 18))
            tile.paste(Image.composite(mini, base, mask))
            path = folder / str(zoom) / str(left // half) / f"{top // half}.webp"
            path.parent.mkdir(parents=True, exist_ok=True)
            tile.save(path, "WEBP", quality=QUALITY, method=4)
            written.append(f"{left // half}/{top // half}")
    return written


def cut(far, near, folder):
    """Writes the pyramid of TILE-pixel tiles: the highest zoom is the canvas itself, each one below halves it, down
    to one tile. A zoom shows `far`, `near` or a mix of them by how wide the canvas is at it. Returns the highest."""
    top = 0
    while TILE * 2 ** top < max(near.size):
        top += 1
    for zoom in range(top, -1, -1):
        factor = 2 ** (top - zoom)
        size = (max(1, -(-near.width // factor)), max(1, -(-near.height // factor)))
        mix = min(1.0, max(0.0, (np.log2(size[0]) - np.log2(FAR)) / (np.log2(NEAR) - np.log2(FAR))))
        level = near if mix == 1 else far if mix == 0 else Image.blend(far, near, mix)
        if factor > 1:
            level = level.resize(size, Image.Resampling.LANCZOS)
        for x in range(0, level.width, TILE):
            for y in range(0, level.height, TILE):
                tile = Image.new("RGB", (TILE, TILE), (29, 24, 18))
                tile.paste(level.crop((x, y, min(x + TILE, level.width), min(y + TILE, level.height))))
                path = folder / str(zoom) / str(x // TILE) / f"{y // TILE}.webp"
                path.parent.mkdir(parents=True, exist_ok=True)
                tile.save(path, "WEBP", quality=QUALITY, method=6)
    return top


def main():
    ap = argparse.ArgumentParser(description="Build the map page's picture of the world")
    ap.add_argument("cache", type=Path)
    ap.add_argument("out", type=Path)
    ap.add_argument("--preview", action="store_true", help="also write the world from far and from near as two pictures")
    ap.add_argument("--install", type=Path, help="the World of Warcraft folder of a French client: textures are read "
                                                 "from it, not downloaded")
    args = ap.parse_args()
    world = World(GameData(args.cache, args.install))
    far, near, land, continents, zones = pictures(world)
    args.out.mkdir(parents=True, exist_ok=True)
    top = cut(far, near, args.out / "tiles")
    deep = cut_deep(world, near, land, args.out / "tiles", top + 1)
    rounded = lambda box: [round(v, 1) for v in box]
    described = {
        "build": world.data.build, "tile": TILE, "size": near.size, "max_zoom": top, "deep": deep,
        "continents": {c: {"name": world.maps[c]["Name_lang"], "box": rounded(box)} for c, box in continents.items()},
        "zones": {z: {"name": world.maps[z]["Name_lang"], "continent": c, "box": rounded(box)} for z, (c, box) in zones.items()}}
    (args.out / "world.json").write_text(json.dumps(described, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    if args.preview:
        for name, picture in (("far", far), ("near", near)):
            small = picture.copy()
            small.thumbnail((2000, 2000), Image.Resampling.LANCZOS)
            small.save(args.out / f"preview-{name}.jpg", quality=85)
    print(f"{near.width}x{near.height} px, {len(zones)} zones on {len(continents)} continents, zoom 0 to {top}, "
          f"and {len(deep)} tiles of zoom {top + 1}", file=sys.stderr)


if __name__ == "__main__":
    main()
