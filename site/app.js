// The map page of RookieLedger: the world of the game as one picture, cut in tiles (world.json and tiles/, made by
// tools/maps/build_world.py), and on it what the read API says the players' records hold: where veins and herbs were
// gathered and monsters looted, and what each gave.
//
// Everything shown as text comes from this site's own files (names.json, world.json) or is a number of the API:
// the API serves no text of a member, and what it does serve is still written with textContent, never as HTML.
"use strict";

const API = "https://rookieledger-api.21crypto.ch/v1";
const PAGE = 1000;                 // rows asked of the API at once: its most
const SMALL = 10;                  // under this many occasions a rate is told as "3/7", not as a percentage
const DEEPEST = 5;                 // window pixels per pixel of the picture, at the closest
const GLIDE = 260;                 // milliseconds a zoom or a jump takes
const AT_ONCE = 8;                 // tiles asked of the server at the same time
const RETRIES = 4;                 // times a tile the server refused is asked for again
const CELL = 16;                   // window pixels: places of one kind nearer than this are drawn as one mark
// Pixels of the picture, which holds 0.22 a yard (tools/maps/build_world.py): veins gathered nearer than about 8 yards
// stood in one place. It is one vein seen by two players, or one place where the game puts a common ore and, now and
// then, a rarer one instead (gold where iron or mithril stands, silver where tin does): one pin tells both.
const SPOT = 1.8;
const OTHER_ORE = "#ffd23f";       // the dot on the pin of a place that gave more than one ore
// Where the three kinds each have a mark in one square, the marks are their places' middles and fall on each other:
// each kind's is drawn a little aside, its own way, and small, so that all three show and the ground between them.
const ASIDE = { creature: [0, -4.5], herbalism: [-4.5, 3.5], mining: [4.5, 3.5] };
const NOT_ASIDE = [0, 0];
// Pins are told apart from the ground and from each other. Their colours were held against the colours of the map
// itself, every tile of it: none of the three is near any ground the minimap or the painted maps show (CIE76
// distance under 40 for 0.0 % of their pixels; the orange, green and dark red used before were that near 12 %, 3 %
// and 7 % of the minimap's). Each kind also has a shape of its own and a light rim inside a dark one, for who tells
// red from green badly and for the few places a colour still falls on its like.
const COLOURS = { mining: "#19d3ff", herbalism: "#9dff3a", creature: "#ff2a2a" };
const KINDS = { mining: "Filon", herbalism: "Plante", creature: "Monstre" };
const MANY = { mining: "filons", herbalism: "plantes", creature: "endroits à monstres" };
const ORDER = { creature: 0, herbalism: 1, mining: 2 };   // drawn in this order: monsters are everywhere, and go under
const QUALITIES = ["Médiocre", "Commun", "Inhabituel", "Rare", "Épique", "Légendaire"];

const canvas = document.getElementById("map");
const ctx = canvas.getContext("2d");
const $ = (id) => document.getElementById(id);

let world = null;                  // world.json
let names = { items: {}, creatures: {} };   // names.json
let view = { x: 0, y: 0, scale: 1 };   // the pixel of the picture at the centre of the window, and window pixels per pixel of it
let glide = null;                  // the view being moved to: { from, to, since }
const pins = [];                   // { x, y (pixels of the picture), layer, id, kinds, keys, map, u, v, count }
                                   // kinds: [{ id, count }], most gathered first (several only for veins), id that
                                   // of the first; keys: "layer:id" of each kind, made once (the search asks for them
                                   // of every pin); count: of them all
const nodes = new Map();           // node id -> the API's Node
const details = new Map();         // "creature:1674" -> the API's Creature, once asked for
const layers = { mining: true, herbalism: true, creature: true };
let matches = null;                // while searching: the "layer:id" that match
let sought = null;                 // while searching: { wanted, items } (what was typed, the ids of the items it names)
const tiles = new Map();           // "zoom/x/y" -> Image
let chosen = null;                 // the pin whose detail is open
let opened = 0;                    // details opened so far: an answer that comes back for an older one is dropped
let drawn = false;

// --- the world: from a place of the API to a point of the picture -----------------------------------------------

// A place is a zone and a position in it, from its left and top edges; world.json gives the zone's box on the picture.
function toWorld(map, u, v) {
  const zone = world.zones[map];
  if (!zone) return null;
  const [left, top, right, bottom] = zone.box;
  return { x: left + u * (right - left), y: top + v * (bottom - top) };
}

// The zone under a point of the picture, and the position in it. The boxes of neighbours overlap: of those that
// hold the point, the one it is nearest the middle of.
function zoneAt(x, y) {
  let best = null;
  for (const [id, zone] of Object.entries(world.zones)) {
    const [left, top, right, bottom] = zone.box;
    if (x < left || x > right || y < top || y > bottom) continue;
    const u = (x - left) / (right - left), v = (y - top) / (bottom - top);
    const off = Math.max(Math.abs(u - 0.5), Math.abs(v - 0.5));
    if (!best || off < best.off) best = { id, zone, u, v, off };
  }
  return best;
}

// --- drawing --------------------------------------------------------------------------------------------------

function resize() {
  const ratio = window.devicePixelRatio || 1;
  canvas.width = Math.round(canvas.clientWidth * ratio);
  canvas.height = Math.round(canvas.clientHeight * ratio);
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
  if (world) clamp(view);
  draw();
}

function least() {
  return Math.min(canvas.clientWidth / world.size[0], canvas.clientHeight / world.size[1]);
}

function clamp(v) {
  v.scale = Math.min(DEEPEST, Math.max(least(), v.scale));
  v.x = Math.min(world.size[0], Math.max(0, v.x));
  v.y = Math.min(world.size[1], Math.max(0, v.y));
  return v;
}

// Tiles are asked for a few at a time, and one the server refuses (it limits how fast one address may ask) is asked
// for again a little later, each time later, a few times.
const waiting = [];
let loading = 0;

function next() {
  while (loading < AT_ONCE && waiting.length) {
    const image = waiting.pop();          // the last asked for first: what the view shows now
    loading++;
    image.src = `tiles/${image.dataset.key}.webp`;
  }
}

function tile(zoom, x, y) {
  const key = `${zoom}/${x}/${y}`;
  let image = tiles.get(key);
  if (!image) {
    image = new Image();
    image.dataset.key = key;
    image.dataset.tries = "0";
    image.onload = () => { loading--; next(); schedule(); };
    image.onerror = () => {
      loading--;
      const tries = Number(image.dataset.tries) + 1;
      image.dataset.tries = String(tries);
      if (tries <= RETRIES) setTimeout(() => { waiting.push(image); next(); }, 700 * 2 ** tries);
      next();
    };
    tiles.set(key, image);
    waiting.push(image);
    next();
  }
  return image.complete && image.naturalWidth ? image : null;
}

// Draws the tiles of one zoom over the window. Returns false if one of them is not loaded yet.
function drawTiles(zoom) {
  const span = world.tile * 2 ** (world.max_zoom - zoom);   // pixels of the picture one tile of this zoom covers
  const w = canvas.clientWidth, h = canvas.clientHeight;
  const left = view.x - w / 2 / view.scale, top = view.y - h / 2 / view.scale;
  const x0 = Math.max(0, Math.floor(left / span)), y0 = Math.max(0, Math.floor(top / span));
  const x1 = Math.min(Math.ceil(world.size[0] / span) - 1, Math.floor((left + w / view.scale) / span));
  const y1 = Math.min(Math.ceil(world.size[1] / span) - 1, Math.floor((top + h / view.scale) / span));
  let whole = true;
  for (let x = x0; x <= x1; x++) {
    for (let y = y0; y <= y1; y++) {
      // The zoom past the picture's own has tiles only where there is land.
      if (zoom > world.max_zoom && !world.deep.has(`${x}/${y}`)) continue;
      const image = tile(zoom, x, y);
      if (!image) { whole = false; continue; }
      // A hair wider than its place, so that no line of the background shows between two tiles.
      ctx.drawImage(image, (x * span - left) * view.scale, (y * span - top) * view.scale,
        span * view.scale + 0.6, span * view.scale + 0.6);
    }
  }
  return whole;
}

function shown(pin) {
  return layers[pin.layer] && found(pin);
}

// What is drawn is not every place. Far out, the places of one kind that fall in one small square are drawn as one
// mark, at their middle, a little larger the more they are: a frame then costs what the window can hold, not what the
// records hold, and a view of the whole world can be read. The squares are the picture's, not the window's, so a
// mark stays where it is while the map is moved; they halve every two steps of zoom, and each step's marks are kept
// until the places or the search change. At the closest steps every place is its own pin.
// A mark is a pin itself, or { x, y, layer, n, pins } for several.
const marks = new Map();           // step of zoom -> the marks of that step

function marked() {
  const step = Math.round(Math.log2(view.scale) * 2), scale = 2 ** (step / 2);
  let list = marks.get(step);
  if (list) return list;
  if (marks.size > 5) marks.clear();
  if (scale >= DEEPEST / 1.5) {
    list = pins.filter(found);
  } else {
    const size = CELL / scale, squares = new Map();
    for (const pin of pins) {
      if (!found(pin)) continue;
      const key = (Math.floor(pin.y / size) * 4194304 + Math.floor(pin.x / size)) * 4 + ORDER[pin.layer];
      const held = squares.get(key);
      if (!held) squares.set(key, pin);
      else if (held.n) { held.pins.push(pin); held.n++; held.x += pin.x; held.y += pin.y; }
      else squares.set(key, { x: held.x + pin.x, y: held.y + pin.y, layer: pin.layer, n: 2, pins: [held, pin] });
    }
    list = [...squares.values()];
    for (const mark of list) {
      if (mark.n) { mark.x /= mark.n; mark.y /= mark.n; }
    }
  }
  list.sort((a, b) => ORDER[a.layer] - ORDER[b.layer]);
  marks.set(step, list);
  return list;
}

// The places or the search changed: the marks are made again, the counts told again.
function changed() {
  marks.clear();
  count();
  schedule();
}

function screen(pin) {
  return [(pin.x - view.x) * view.scale + canvas.clientWidth / 2, (pin.y - view.y) * view.scale + canvas.clientHeight / 2];
}

function draw() {
  drawn = false;
  if (!world) return;
  if (glide) {
    const t = Math.min(1, (performance.now() - glide.since) / GLIDE), e = 1 - (1 - t) ** 3;
    // The scale moves by equal ratios, so that a zoom feels as fast at its start as at its end.
    view.scale = glide.from.scale * (glide.to.scale / glide.from.scale) ** e;
    if (glide.anchor) {
      // A zoom at the cursor: the point of the picture under it stays under it.
      view.x = glide.anchor.x - glide.anchor.dx / view.scale;
      view.y = glide.anchor.y - glide.anchor.dy / view.scale;
    } else {
      view.x = glide.from.x + (glide.to.x - glide.from.x) * e;
      view.y = glide.from.y + (glide.to.y - glide.from.y) * e;
    }
    clamp(view);
    if (t >= 1) { glide = null; remember(); } else schedule();
  }
  const w = canvas.clientWidth, h = canvas.clientHeight;
  ctx.globalAlpha = 1;
  ctx.fillStyle = "#1d1812";
  ctx.fillRect(0, 0, w, h);
  ctx.imageSmoothingQuality = "high";
  // Between two zooms of the tiles the finer one comes in over the coarser, by how far the view is between them:
  // where the two hold different pictures (the world's map far out, the zones' maps close in, the ground as the
  // game's minimap shows it closest of all), one dissolves into the other as the view moves.
  const exact = world.max_zoom + Math.log2(view.scale);
  const coarse = Math.min(world.max_zoom, Math.max(0, Math.floor(exact)));
  if (coarse > 1) drawTiles(coarse - 2);            // something to look at while the others load
  drawTiles(coarse);
  if (exact > coarse && (coarse < world.max_zoom || world.deep.size)) {
    ctx.globalAlpha = Math.min(1, (exact - coarse) * 1.5);
    drawTiles(coarse + 1);
    ctx.globalAlpha = 1;
  }
  const radius = Math.round(2 * Math.max(3.5, Math.min(7, 4.5 + Math.log2(view.scale) * 1.2))) / 2;
  const dx = w / 2 - view.x * view.scale, dy = h / 2 - view.y * view.scale;
  for (const mark of marked()) {
    if (!layers[mark.layer] || mark === chosen) continue;
    const aside = mark.n ? ASIDE[mark.layer] : NOT_ASIDE;
    const sx = mark.x * view.scale + dx + aside[0], sy = mark.y * view.scale + dy + aside[1];
    if (sx < -14 || sy < -14 || sx > w + 14 || sy > h + 14) continue;
    stamp(mark.layer, sx, sy, mark.n ? 2.5 + Math.round(Math.min(2, Math.log2(mark.n) / 3)) / 2 : radius,
      !mark.n && mark.kinds.length > 1);
  }
  // The pin whose detail is open, over the others and larger, also where a mark stands for it and its neighbours.
  if (chosen && shown(chosen)) paint(ctx, chosen.layer, ...screen(chosen), radius + 3, true, chosen.kinds.length > 1);
  float();
}

// A pin's picture is drawn once per kind and size and stamped from then on: drawing its outline anew for every pin
// of every frame took three times as long.
const stamps = new Map();

function stamp(layer, x, y, r, mixed) {
  const ratio = window.devicePixelRatio || 1, key = `${layer}/${r}/${ratio}/${mixed ? 1 : 0}`;
  let image = stamps.get(key);
  if (!image) {
    const half = Math.ceil(r * 1.35 + 4);
    image = document.createElement("canvas");
    image.width = image.height = Math.ceil(2 * half * ratio);
    const c = image.getContext("2d");
    c.scale(image.width / (2 * half), image.width / (2 * half));
    paint(c, layer, half, half, r, false, mixed);
    stamps.set(key, image);
    image.half = half;
  }
  // On a whole pixel of the screen: between two it would be blurred.
  ctx.drawImage(image, Math.round((x - image.half) * ratio) / ratio, Math.round((y - image.half) * ratio) / ratio,
    2 * image.half, 2 * image.half);
}

function paint(c, layer, x, y, r, strong, mixed) {
  outline(c, layer, x, y, r);
  c.lineJoin = "round";
  c.lineWidth = strong ? 6 : 4;
  c.strokeStyle = "rgba(20,14,8,.85)";
  c.stroke();                                       // the dark rim, widest, mostly hidden by the next
  c.lineWidth = strong ? 3.5 : 2;
  c.strokeStyle = "#fff";
  c.stroke();
  c.fillStyle = COLOURS[layer];
  c.fill();
  if (!mixed) return;
  // At the upper right, where a diamond leaves room: a small dot for the other ore of the place.
  c.beginPath();
  c.arc(x + r * 0.8, y - r * 0.8, Math.max(2.5, r * 0.45), 0, 2 * Math.PI);
  c.lineWidth = 2;
  c.strokeStyle = "rgba(20,14,8,.85)";
  c.stroke();
  c.fillStyle = OTHER_ORE;
  c.fill();
}

// Keeps the detail card beside the pin it is about, as the map moves: to its right, or to its left where the right
// has no room, and inside the window. While the pin is out of the window the card is out of sight. On a narrow
// screen the card is a sheet at the bottom (the style sheet's doing) and stays there.
function float() {
  const card = $("detail");
  if (!chosen || card.hidden) return;
  if (window.matchMedia("(max-width: 700px)").matches) {
    card.style.left = card.style.top = card.style.right = card.style.visibility = "";
    return;
  }
  const [sx, sy] = screen(chosen), w = canvas.clientWidth, h = canvas.clientHeight;
  const width = card.offsetWidth, height = card.offsetHeight, gap = 18, edge = 8;
  let left = sx + gap;
  if (left + width > w - edge) left = sx - gap - width;
  left = Math.max(edge, Math.min(w - width - edge, left));
  const top = Math.max(edge, Math.min(h - height - edge, sy - Math.min(height / 2, 44)));
  card.style.left = left + "px";
  card.style.top = top + "px";
  card.style.right = "auto";
  card.style.visibility = sx < -12 || sy < -12 || sx > w + 12 || sy > h + 12 ? "hidden" : "";
}

// The outline of a pin about a point: a diamond for a vein, a disc for a herb, a triangle for a monster, of about
// the same area.
function outline(c, layer, x, y, r) {
  c.beginPath();
  if (layer === "mining") {
    const d = r * 1.25;
    c.moveTo(x, y - d); c.lineTo(x + d, y); c.lineTo(x, y + d); c.lineTo(x - d, y);
  } else if (layer === "creature") {
    const d = r * 1.35;
    c.moveTo(x, y - d); c.lineTo(x + d * 0.92, y + d * 0.62); c.lineTo(x - d * 0.92, y + d * 0.62);
  } else {
    c.arc(x, y, r, 0, 2 * Math.PI);
    return;
  }
  c.closePath();
}

function schedule() {
  if (!drawn) { drawn = true; requestAnimationFrame(draw); }
}

// --- moving about ---------------------------------------------------------------------------------------------

// Zooms by a factor about a point of the window, gliding. A zoom asked for during another carries on from its goal.
function zoomAt(factor, px, py, at_once) {
  if (!world) return;
  const w = canvas.clientWidth, h = canvas.clientHeight;
  const goal = Math.min(DEEPEST, Math.max(least(), (glide && glide.anchor ? glide.to.scale : view.scale) * factor));
  const anchor = { x: view.x + (px - w / 2) / view.scale, y: view.y + (py - h / 2) / view.scale, dx: px - w / 2, dy: py - h / 2 };
  if (at_once) {
    glide = null;
    view.scale = goal;
    view.x = anchor.x - anchor.dx / goal;
    view.y = anchor.y - anchor.dy / goal;
    clamp(view);
    remember();
  } else {
    glide = { from: { ...view }, to: { scale: goal }, anchor, since: performance.now() };
  }
  schedule();
}

// Glides to a box of the picture, so that it fills most of the window.
function goTo(box) {
  const [left, top, right, bottom] = box;
  const to = clamp({ x: (left + right) / 2, y: (top + bottom) / 2,
    scale: 0.9 * Math.min(canvas.clientWidth / (right - left), canvas.clientHeight / (bottom - top)) });
  glide = { from: { ...view }, to, since: performance.now() };
  schedule();
}

const pointers = new Map();
let moved = 0, pinch = 0;

canvas.addEventListener("pointerdown", (event) => {
  canvas.setPointerCapture(event.pointerId);
  pointers.set(event.pointerId, [event.clientX, event.clientY]);
  moved = 0;
  pinch = 0;
  glide = null;
  canvas.classList.add("dragging");
});

canvas.addEventListener("pointermove", (event) => {
  const before = pointers.get(event.pointerId);
  if (!before) return hover(event);
  if (!world) return;
  pointers.set(event.pointerId, [event.clientX, event.clientY]);
  if (pointers.size === 1) {
    view.x -= (event.clientX - before[0]) / view.scale;
    view.y -= (event.clientY - before[1]) / view.scale;
    moved += Math.abs(event.clientX - before[0]) + Math.abs(event.clientY - before[1]);
    clamp(view);
  } else if (pointers.size === 2) {
    const [a, b] = [...pointers.values()];
    const apart = Math.hypot(a[0] - b[0], a[1] - b[1]);
    const box = canvas.getBoundingClientRect();
    if (pinch) zoomAt(apart / pinch, (a[0] + b[0]) / 2 - box.left, (a[1] + b[1]) / 2 - box.top, true);
    pinch = apart;
    moved += 10;
  }
  schedule();
});

function release(event) {
  if (!pointers.delete(event.pointerId)) return;
  if (!pointers.size) canvas.classList.remove("dragging");
  pinch = 0;
  if (event.type === "pointerup" && moved < 6) pick(event);
  remember();
}
canvas.addEventListener("pointerup", release);
canvas.addEventListener("pointercancel", release);

canvas.addEventListener("wheel", (event) => {
  event.preventDefault();
  const box = canvas.getBoundingClientRect();
  // A wheel's notch glides; a touchpad sends many small moves, which are followed as they come.
  const small = !event.deltaMode && Math.abs(event.deltaY) < 40;
  zoomAt(Math.exp(-event.deltaY * (event.deltaMode ? 0.08 : 0.0022)), event.clientX - box.left, event.clientY - box.top, small);
}, { passive: false });

$("zoom-in").addEventListener("click", () => zoomAt(1.8, canvas.clientWidth / 2, canvas.clientHeight / 2));
$("zoom-out").addEventListener("click", () => zoomAt(1 / 1.8, canvas.clientWidth / 2, canvas.clientHeight / 2));
window.addEventListener("resize", resize);

function at(event) {
  const box = canvas.getBoundingClientRect();
  return [event.clientX - box.left, event.clientY - box.top];
}

// The mark nearest a point of the window, within reach: a pin, or the mark of several.
function nearest(px, py, reach) {
  let best = null, least = reach * reach;
  const dx = canvas.clientWidth / 2 - view.x * view.scale, dy = canvas.clientHeight / 2 - view.y * view.scale;
  for (const mark of marked()) {
    if (!layers[mark.layer]) continue;
    const aside = mark.n ? ASIDE[mark.layer] : NOT_ASIDE;
    const d = (mark.x * view.scale + dx + aside[0] - px) ** 2 + (mark.y * view.scale + dy + aside[1] - py) ** 2;
    if (d <= least) { least = d; best = mark; }
  }
  return best;
}

function hover(event) {
  if (!world) return;
  const [px, py] = at(event);
  const here = zoneAt(view.x + (px - canvas.clientWidth / 2) / view.scale, view.y + (py - canvas.clientHeight / 2) / view.scale);
  const pin = nearest(px, py, 9);
  canvas.style.cursor = pin ? "pointer" : "";
  $("where").textContent = pin && pin.n ? `${pin.n} ${MANY[pin.layer]} : cliquer pour approcher`
    : pin ? label(pin) + " · " + place(pin.map, pin.u, pin.v)
    : here ? place(here.id, here.u, here.v) : "Azeroth";
}

function place(map, u, v) {
  return `${world.zones[map].name} ${(u * 100).toFixed(1)}, ${(v * 100).toFixed(1)}`;
}

// --- what a pin is --------------------------------------------------------------------------------------------

function item(id) {
  return names.items[id] || ["objet " + id, 1];
}

// A vein or a herb has no name in the game's tables: it is named after what it most often gives.
function material(id) {
  const node = nodes.get(id);
  const most = node && node.materials.slice().sort((a, b) => b.times - a.times)[0];
  return most ? item(most.item)[0] : null;
}

function nodeName(id) {
  const node = nodes.get(id), named = material(id);
  return named ? `${KINDS[node.kind]} : ${named}` : `${node ? KINDS[node.kind] : "Gisement"} ${id}`;
}

// A monster's name is known if the install the names were made from has met it; else its number stands for it.
function creatureName(id) {
  return names.creatures[id] || "Monstre " + id;
}

function label(pin) {
  if (pin.layer === "creature") return creatureName(pin.id);
  if (pin.kinds.length === 1) return nodeName(pin.id);
  return `${KINDS[pin.layer]} : ${pin.kinds.map((k) => material(k.id) || k.id).join(" ou ")}`;
}

function rate(times, total) {
  if (!total) return "—";
  return total < SMALL ? `${times}/${total}` : `${Math.round(100 * times / total)} %`;
}

function coin(copper) {
  const c = Math.round(copper), parts = [];
  if (c >= 10000) parts.push(Math.floor(c / 10000) + " or");
  if (c >= 100 && Math.floor(c / 100) % 100) parts.push(Math.floor(c / 100) % 100 + " argent");
  if (c % 100 || !parts.length) parts.push(c % 100 + " cuivre");
  return parts.join(" ");
}

function element(tag, text, className) {
  const e = document.createElement(tag);
  if (text !== undefined) e.textContent = text;
  if (className) e.className = className;
  return e;
}

function table(heading, rows) {
  const t = element("table"), head = t.createTHead().insertRow();
  heading.forEach((text, i) => { const th = element("th", text); if (i) th.style.textAlign = "right"; head.append(th); });
  const body = t.createTBody();
  for (const cells of rows) {
    const row = body.insertRow();
    cells.forEach((cell, i) => {
      const td = row.insertCell();
      if (i) td.className = "n";
      td.append(cell instanceof Node ? cell : document.createTextNode(cell));
    });
  }
  return t;
}

function itemCell(id, note) {
  const [name, quality] = item(id);
  const span = element("span", name, "q" + quality);
  span.title = QUALITIES[quality] || "";
  if (!note) return span;
  const wrap = element("span");
  wrap.append(span, element("span", " " + note, "quest"));
  return wrap;
}

function yields(rows, total) {
  return rows.slice().sort((a, b) => b.times - a.times).map((y) => [
    itemCell(y.item), rate(y.times, total), y.average_quantity > 1.05 ? "×" + y.average_quantity.toFixed(1) : ""]);
}

// A monster's detail comes from the API: an answer that arrives once another card was opened is not shown.
// A place of several ores shows one of them, kind (else the first the search names, else the most gathered), and
// names the others, each a button that shows it instead.
async function open(pin, kind) {
  const mine = ++opened;
  chosen = pin;
  schedule();
  const body = $("detail-body");
  if (pin.layer !== "creature") {
    kind = kind || pin.kinds.find((k) => sought && kindFits(k.id)) || pin.kinds[0];
    body.replaceChildren(element("h2", nodeName(kind.id)), element("div", place(pin.map, pin.u, pin.v), "sub"));
    $("detail").hidden = false;
    const others = pin.kinds.filter((k) => k !== kind);
    if (others.length) {
      const line = element("div", "Ce filon peut aussi être : ", "sub");
      others.forEach((k, i) => {
        const other = element("button", material(k.id) || nodeName(k.id), "other");
        other.addEventListener("click", () => open(pin, k));
        line.append(i ? ", " : "", other, ` (${k.count} fois sur ${pin.count})`);
      });
      body.append(line);
    }
    const node = nodes.get(kind.id);
    // A kind first gathered after the page asked for the kinds is not among them yet.
    if (!node) { body.append(element("div", `Récolté ${kind.count}× ici.`, "sub")); return; }
    body.append(element("div", `Récolté ${kind.count}× ici, ${node.gathers}× en tout, en ${node.place_count} endroits.`, "sub"),
      table(["Donne", "Fréquence", ""], yields(node.materials, node.gathers)));
    return;
  }
  body.replaceChildren(element("h2", label(pin)), element("div", place(pin.map, pin.u, pin.v), "sub"));
  $("detail").hidden = false;
  const key = "creature:" + pin.id;
  if (!details.has(key)) {
    const loading = element("div", "Chargement…", "sub");
    body.append(loading);
    let answer;
    try {
      answer = await get(`/creatures/${pin.id}`);
    } catch (error) {
      // Only into the detail that asked: another may be open by now, or the same one opened again.
      if (mine === opened) loading.textContent = "Le détail n'a pas pu être chargé.";
      return;
    }
    details.set(key, answer);
    if (mine !== opened) return;
    loading.remove();
  }
  const c = details.get(key);
  body.append(element("div", `Fouillé ${pin.count}× ici, ${c.corpses}× en tout.`
    + (c.coin_average ? ` ${coin(c.coin_average)} en moyenne.` : ""), "sub"));
  if (c.drops.length) body.append(table(["Butin", "Fréquence", ""], yields(c.drops, c.corpses)));
  if (c.quest_drops.length) {
    body.append(table(["Objets de quête", "Avec la quête", ""], c.quest_drops.map((q) => [
      itemCell(q.item, "(quête)"), rate(q.drops, q.chances), ""])));
  }
  if (!c.drops.length && !c.quest_drops.length) body.append(element("div", "Aucun objet relevé.", "sub"));
  schedule();                       // the card has grown since it was placed: place it again
}

function pick(event) {
  const [px, py] = at(event);
  const pin = nearest(px, py, 10);
  // A mark of several is approached, until its places come apart: at the closest every place is its own pin.
  if (pin && pin.n) zoomAt(2, px, py);
  else if (pin) open(pin);
  else closeDetail();
}

function closeDetail() {
  opened++;
  chosen = null;
  $("detail").hidden = true;
  schedule();
}
$("close").addEventListener("click", closeDetail);

// --- filters --------------------------------------------------------------------------------------------------

function count() {
  const totals = { mining: 0, herbalism: 0, creature: 0 };
  for (const pin of pins) {
    if (found(pin)) totals[pin.layer]++;
  }
  for (const [layer, n] of Object.entries(totals)) $("n-" + layer).textContent = n;
}

// Whether a pin is shown by the search: by one of its kinds, for a place of several ores.
function found(pin) {
  return !matches || pin.keys.some((key) => matches.has(key));
}

for (const box of document.querySelectorAll("[data-layer]")) {
  box.addEventListener("change", () => { layers[box.dataset.layer] = box.checked; schedule(); });
}

// A search matches a vein or a herb by what it gives, a monster by its name, its number or what it dropped (asked
// of the API: its items are not loaded until then). Gives the keys of the pin that match.
function fitting(pin) {
  const { wanted } = sought;
  if (pin.layer === "creature") {
    return String(pin.id) === wanted || creatureName(pin.id).toLowerCase().includes(wanted) ? pin.keys : [];
  }
  return pin.kinds.filter((k) => kindFits(k.id)).map((k) => pin.layer + ":" + k.id);
}

function kindFits(id) {
  const { wanted, items } = sought, node = nodes.get(id);
  return Boolean(node && node.materials.some((m) => items.has(m.item))) || nodeName(id).toLowerCase().includes(wanted);
}

let searching = 0;
$("search").addEventListener("input", async (event) => {
  const wanted = event.target.value.trim().toLowerCase();
  const mine = ++searching;
  if (!wanted) { matches = sought = null; changed(); return; }
  const ids = Object.entries(names.items).filter(([, [name]]) => name.toLowerCase().includes(wanted)).map(([id]) => Number(id));
  sought = { wanted, items: new Set(ids) };
  const fit = new Set();
  for (const pin of pins) {
    for (const key of fitting(pin)) fit.add(key);
  }
  matches = fit;
  changed();
  // The monsters that dropped one of the items: one question per item, for the few items a search of three letters
  // or more names among those ever recorded.
  if (wanted.length < 3) return;
  const known = await knownItems();
  for (const id of ids.filter((id) => known.has(id)).slice(0, 12)) {
    try {
      for (const creature of await all(`/creatures?item=${id}`)) fit.add("creature:" + creature.id);
    } catch (error) { /* the search then shows what it already found */ }
    if (mine !== searching) return;
    changed();
  }
});

let itemsSeen = null;
function knownItems() {
  // A question that failed is asked again at the next search: it does not stand for "no item" from then on.
  itemsSeen = itemsSeen || all("/items").then((rows) => new Set(rows.map((row) => row.id)),
    () => { itemsSeen = null; return new Set(); });
  return itemsSeen;
}

// --- the API ----------------------------------------------------------------------------------------------------

// The API's host limits how fast one address may ask, as the site's does: a question it refuses is asked again a
// little later, each time later, a few times. Its refusal can come without the API's own headers, which the browser
// then reports as a failed fetch, not as an answer.
async function get(path) {
  for (let tries = 1; ; tries++) {
    let response = null;
    try {
      response = await fetch(API + path, { headers: { Accept: "application/json" } });
    } catch (error) {
      if (tries > RETRIES) throw error;
    }
    if (response) {
      if (response.ok) return response.json();
      if ((response.status !== 429 && response.status !== 503) || tries > RETRIES) throw new Error(path + ": " + response.status);
    }
    await new Promise((resume) => setTimeout(resume, 700 * 2 ** tries));
  }
}

async function all(path) {
  const rows = [];
  let cursor = null;
  do {
    const page = await get(`${path}${path.includes("?") ? "&" : "?"}limit=${PAGE}${cursor ? "&cursor=" + encodeURIComponent(cursor) : ""}`);
    rows.push(...page.data);
    cursor = page.next_cursor;
  } while (cursor);
  return rows;
}

function pin(place, layer, kinds) {
  const made = { ...place, layer, id: kinds[0].id, kinds, keys: kinds.map((k) => layer + ":" + k.id),
    count: kinds.reduce((sum, k) => sum + k.count, 0) };
  pins.push(made);
  // A search typed while the places were still coming in also takes them.
  if (matches && sought) for (const key of fitting(made)) matches.add(key);
}

// The places of veins nearer than SPOT to the most gathered among them are one: [{ x, y, map, u, v (its), kinds }].
// The places are looked for in squares of SPOT's side, the one of the place and the eight around it.
function spots(veins) {
  const made = [], squares = new Map();
  for (const vein of veins.sort((a, b) => b.count - a.count)) {
    const sx = Math.floor(vein.x / SPOT), sy = Math.floor(vein.y / SPOT);
    let spot = null;
    for (let i = -1; i <= 1 && !spot; i++) {
      for (let j = -1; j <= 1 && !spot; j++) {
        spot = (squares.get(`${sx + i},${sy + j}`) || []).find((s) => Math.hypot(s.x - vein.x, s.y - vein.y) <= SPOT);
      }
    }
    if (!spot) {
      const { x, y, map, u, v } = vein;
      spot = { x, y, map, u, v, kinds: [] };
      made.push(spot);
      squares.set(`${sx},${sy}`, [...(squares.get(`${sx},${sy}`) || []), spot]);
    }
    const kind = spot.kinds.find((k) => k.id === vein.id);
    if (kind) kind.count += vein.count;
    else spot.kinds.push({ id: vein.id, count: vein.count });
  }
  for (const spot of made) spot.kinds.sort((a, b) => b.count - a.count);
  return made;
}

// Every place comes in one answer of the API, written short: per map and kind, three numbers a place (see /places
// in the API's own description). Returns how many places lie on maps the page does not show.
async function load() {
  const [kinds, places] = await Promise.all([all("/nodes"), get("/places")]);
  for (const node of kinds) nodes.set(node.id, node);
  let elsewhere = 0;
  const veins = [];
  for (const map of places.maps) {
    for (const [layer, held] of [["mining", map.mining], ["herbalism", map.herbalism], ["creature", map.creatures]]) {
      for (const [id, flat] of Object.entries(held)) {
        if (!world.zones[map.id]) { elsewhere += flat.length / 3; continue; }
        for (let i = 0; i < flat.length; i += 3) {
          const u = flat[i] / 1000, v = flat[i + 1] / 1000, place = { ...toWorld(map.id, u, v), map: map.id, u, v };
          if (layer === "mining") veins.push({ ...place, id: Number(id), count: flat[i + 2] });
          else pin(place, layer, [{ id: Number(id), count: flat[i + 2] }]);
        }
      }
    }
  }
  for (const { kinds: held, ...place } of spots(veins)) pin(place, "mining", held);
  changed();
  return elsewhere;
}

// --- where the page was left: in the address, so that a link shows the same thing ------------------------------

// Written once the view has stayed still a moment: browsers refuse (Firefox and Safari by throwing) an address
// rewritten as often as a touchpad or a pinch moves the view.
let remembering = 0;
function remember() {
  if (!world) return;
  clearTimeout(remembering);
  remembering = setTimeout(() => {
    try {
      history.replaceState(null, "", `#${view.x.toFixed(0)}/${view.y.toFixed(0)}/${view.scale.toFixed(3)}`);
    } catch (error) { /* refused all the same: the address keeps the view before */ }
  }, 300);
}

function recalled() {
  const parts = location.hash.slice(1).split("/").map(Number);
  if (parts.length !== 3 || !parts.every(Number.isFinite) || parts[2] <= 0) return false;
  view = clamp({ x: parts[0], y: parts[1], scale: parts[2] });
  return true;
}

async function start() {
  try {
    [world, names] = await Promise.all([
      fetch("world.json").then((r) => r.json()), fetch("names.json").then((r) => r.json())]);
    names.creatures = names.creatures || {};
  } catch (error) {
    $("status").textContent = "La carte n'a pas pu être chargée.";
    return;
  }
  world.deep = new Set(world.deep || []);
  const whole = element("button", "Le monde");
  whole.addEventListener("click", () => goTo([0, 0, ...world.size]));
  $("continents").append(whole);
  for (const c of Object.values(world.continents)) {
    const button = element("button", c.name);
    button.addEventListener("click", () => goTo(c.box));
    $("continents").append(button);
  }
  // With no view in the address, the page opens on the whole world. The view is set before the first drawing, which
  // would otherwise ask for the tiles of a view no one sees.
  if (!recalled()) view = clamp({ x: world.size[0] / 2, y: world.size[1] / 2, scale: 0 });
  resize();
  try {
    const elsewhere = await load();
    $("status").textContent = `${pins.length} endroits relevés` + (elsewhere ? `, ${elsewhere} hors de ces cartes` : "") + ".";
  } catch (error) {
    $("status").textContent = "Les relevés n'ont pas pu être chargés : la carte est vide pour l'instant.";
  }
}

start();
