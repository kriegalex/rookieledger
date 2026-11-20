// The map page of RookieLedger: the world of the game as one picture, cut in tiles (world.json and tiles/, made by
// tools/maps/build_world.py), and on it what the read API says the guild's records hold: where veins and herbs were
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
const COLOURS = { mining: "#e8762c", herbalism: "#3fa34d", creature: "#c0392b" };
const KINDS = { mining: "Filon", herbalism: "Plante", creature: "Monstre" };
const QUALITIES = ["Médiocre", "Commun", "Inhabituel", "Rare", "Épique", "Légendaire"];

const canvas = document.getElementById("map");
const ctx = canvas.getContext("2d");
const $ = (id) => document.getElementById(id);

let world = null;                  // world.json
let names = { items: {}, creatures: {} };   // names.json
let view = { x: 0, y: 0, scale: 1 };   // the pixel of the picture at the centre of the window, and window pixels per pixel of it
let glide = null;                  // the view being moved to: { from, to, since }
const pins = [];                   // { x, y (pixels of the picture), layer, id, map, u, v, count }
const nodes = new Map();           // node id -> the API's Node
const details = new Map();         // "creature:1674" -> the API's Creature, once asked for
const layers = { mining: true, herbalism: true, creature: true };
let matches = null;                // while searching: the "layer:id" that match
const tiles = new Map();           // "zoom/x/y" -> Image
let chosen = null;                 // the pin whose detail is open
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
  return layers[pin.layer] && (!matches || matches.has(pin.layer + ":" + pin.id));
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
  const radius = Math.max(3.5, Math.min(7, 4.5 + Math.log2(view.scale) * 1.2));
  for (const pin of pins) {
    if (!shown(pin)) continue;
    const [sx, sy] = screen(pin);
    if (sx < -10 || sy < -10 || sx > w + 10 || sy > h + 10) continue;
    ctx.beginPath();
    ctx.arc(sx, sy, pin === chosen ? radius + 3 : radius, 0, 2 * Math.PI);
    ctx.fillStyle = COLOURS[pin.layer];
    ctx.globalAlpha = pin === chosen ? 1 : 0.88;
    ctx.fill();
    ctx.globalAlpha = 1;
    ctx.lineWidth = pin === chosen ? 2.5 : 1;
    ctx.strokeStyle = pin === chosen ? "#fff" : "rgba(0,0,0,.7)";
    ctx.stroke();
  }
}

function schedule() {
  if (!drawn) { drawn = true; requestAnimationFrame(draw); }
}

// --- moving about ---------------------------------------------------------------------------------------------

// Zooms by a factor about a point of the window, gliding. A zoom asked for during another carries on from its goal.
function zoomAt(factor, px, py, at_once) {
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

function nearest(px, py, reach) {
  let best = null, least = reach * reach;
  for (const pin of pins) {
    if (!shown(pin)) continue;
    const [sx, sy] = screen(pin);
    const d = (sx - px) ** 2 + (sy - py) ** 2;
    if (d <= least) { least = d; best = pin; }
  }
  return best;
}

function hover(event) {
  if (!world) return;
  const [px, py] = at(event);
  const here = zoneAt(view.x + (px - canvas.clientWidth / 2) / view.scale, view.y + (py - canvas.clientHeight / 2) / view.scale);
  const pin = nearest(px, py, 9);
  canvas.style.cursor = pin ? "pointer" : "";
  $("where").textContent = pin ? label(pin) + " · " + place(pin.map, pin.u, pin.v)
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
function nodeName(id) {
  const node = nodes.get(id);
  const most = node && node.materials.slice().sort((a, b) => b.times - a.times)[0];
  return most ? `${KINDS[node.kind]} : ${item(most.item)[0]}` : `${node ? KINDS[node.kind] : "Gisement"} ${id}`;
}

// A monster's name is known if the install the names were made from has met it; else its number stands for it.
function creatureName(id) {
  return names.creatures[id] || "Monstre " + id;
}

function label(pin) {
  return pin.layer === "creature" ? creatureName(pin.id) : nodeName(pin.id);
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

async function open(pin) {
  chosen = pin;
  schedule();
  const body = $("detail-body");
  body.replaceChildren(element("h2", label(pin)), element("div", place(pin.map, pin.u, pin.v), "sub"));
  $("detail").hidden = false;
  if (pin.layer !== "creature") {
    const node = nodes.get(pin.id);
    body.append(element("div", `Récolté ${pin.count}× ici, ${node.gathers}× en tout, en ${node.place_count} endroits.`, "sub"),
      table(["Donne", "Fréquence", ""], yields(node.materials, node.gathers)));
    return;
  }
  const key = "creature:" + pin.id;
  if (!details.has(key)) {
    body.append(element("div", "Chargement…", "sub"));
    try {
      details.set(key, await get(`/creatures/${pin.id}`));
    } catch (error) {
      body.lastChild.textContent = "Le détail n'a pas pu être chargé.";
      return;
    }
    if (chosen !== pin) return;
    body.lastChild.remove();
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
}

function pick(event) {
  const [px, py] = at(event);
  const pin = nearest(px, py, 10);
  if (pin) open(pin); else closeDetail();
}

function closeDetail() {
  chosen = null;
  $("detail").hidden = true;
  schedule();
}
$("close").addEventListener("click", closeDetail);

// --- filters --------------------------------------------------------------------------------------------------

function count() {
  const totals = { mining: 0, herbalism: 0, creature: 0 };
  for (const pin of pins) {
    if (!matches || matches.has(pin.layer + ":" + pin.id)) totals[pin.layer]++;
  }
  for (const [layer, n] of Object.entries(totals)) $("n-" + layer).textContent = n;
}

for (const box of document.querySelectorAll("[data-layer]")) {
  box.addEventListener("change", () => { layers[box.dataset.layer] = box.checked; schedule(); });
}

// A search matches a vein or a herb by what it gives, a monster by its name, its number or what it dropped (asked
// of the API: its items are not loaded until then).
let searching = 0;
$("search").addEventListener("input", async (event) => {
  const wanted = event.target.value.trim().toLowerCase();
  const mine = ++searching;
  if (!wanted) { matches = null; count(); schedule(); return; }
  const found = new Set();
  const ids = Object.entries(names.items).filter(([, [name]]) => name.toLowerCase().includes(wanted)).map(([id]) => Number(id));
  const items = new Set(ids);
  for (const [id, node] of nodes) {
    if (node.materials.some((m) => items.has(m.item)) || nodeName(id).toLowerCase().includes(wanted)) found.add(node.kind + ":" + id);
  }
  for (const pin of pins) {
    if (pin.layer === "creature" && (String(pin.id) === wanted || creatureName(pin.id).toLowerCase().includes(wanted))) {
      found.add("creature:" + pin.id);
    }
  }
  matches = found;
  count();
  schedule();
  // The monsters that dropped one of the items: one question per item, for the few items a search of three letters
  // or more names among those the guild ever saw.
  if (wanted.length < 3) return;
  const known = await knownItems();
  for (const id of ids.filter((id) => known.has(id)).slice(0, 12)) {
    try {
      for (const creature of await all(`/creatures?item=${id}`)) found.add("creature:" + creature.id);
    } catch (error) { /* the search then shows what it already found */ }
    if (mine !== searching) return;
    count();
    schedule();
  }
});

let itemsSeen = null;
function knownItems() {
  itemsSeen = itemsSeen || all("/items").then((rows) => new Set(rows.map((row) => row.id)), () => new Set());
  return itemsSeen;
}

// --- the API ----------------------------------------------------------------------------------------------------

async function get(path) {
  const response = await fetch(API + path, { headers: { Accept: "application/json" } });
  if (!response.ok) throw new Error(path + ": " + response.status);
  return response.json();
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

function pin(layer, id, row, count) {
  const point = toWorld(row.map, row.x, row.y);
  if (point) pins.push({ ...point, layer, id, map: row.map, u: row.x, v: row.y, count });
}

async function load() {
  let elsewhere = 0;
  for (const node of await all("/nodes")) nodes.set(node.id, node);
  for (const map of await all("/maps")) {
    if (!world.zones[map.id]) { elsewhere += map.node_place_count + map.creature_place_count; continue; }
    const [veins, beasts] = await Promise.all([
      map.node_place_count ? all(`/maps/${map.id}/node-places`) : [],
      map.creature_place_count ? all(`/maps/${map.id}/creature-places`) : []]);
    for (const row of veins) pin(row.kind, row.node, row, row.gathers);
    for (const row of beasts) pin("creature", row.creature, row, row.corpses);
    count();
    schedule();
  }
  return elsewhere;
}

// --- where the page was left: in the address, so that a link shows the same thing ------------------------------

function remember() {
  if (world) history.replaceState(null, "", `#${view.x.toFixed(0)}/${view.y.toFixed(0)}/${view.scale.toFixed(3)}`);
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
  resize();
  // With no view in the address, the page opens on the whole world.
  if (!recalled()) view = clamp({ x: world.size[0] / 2, y: world.size[1] / 2, scale: 0 });
  schedule();
  try {
    const elsewhere = await load();
    $("status").textContent = `${pins.length} endroits relevés` + (elsewhere ? `, ${elsewhere} hors de ces cartes` : "") + ".";
  } catch (error) {
    $("status").textContent = "Les relevés n'ont pas pu être chargés : la carte est vide pour l'instant.";
  }
}

start();
