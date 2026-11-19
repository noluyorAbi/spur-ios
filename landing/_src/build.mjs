// Generates the invented street grid and the map overlays, then writes ../index.html from
// index.src.html. Run it with "node _src/build.mjs" from the landing directory.
// The grid is made up: nothing here is traced from real map data.
import fs from "node:fs";
import path from "node:path";

const HERE = path.dirname(new URL(import.meta.url).pathname);
const OUT = path.join(HERE, "..", "index.html");

const r1 = (n) => Math.round(n * 10) / 10;
const P = (p) => `${r1(p[0])} ${r1(p[1])}`;
const poly = (a) => "M " + a.map(P).join(" L ");
const dist = (a, b) => Math.hypot(b[0] - a[0], b[1] - a[1]);
const lerp = (a, b, t) => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];
const deg = (a, b) => (Math.atan2(b[1] - a[1], b[0] - a[0]) * 180) / Math.PI;

// ------------------------------------------------------------------ the city
const XS = [40, 130, 215, 310, 400, 480, 575, 660, 750, 845, 930, 1020, 1110, 1195, 1290, 1380, 1470, 1560, 1650, 1745, 1830, 1925, 2015, 2110, 2200];
const YS = [-300, -210, -120, -30, 60, 150, 235, 330, 410, 500, 590, 675, 770, 860, 950, 1040, 1130, 1225, 1310, 1400];
const ART_X = [660, 1020, 1380, 1830];
const ART_Y = [-120, 330, 590, 860, 1225];

// The river splits an old town on a turned grid from the newer square grid.
const RIVER = "M 640 -420 C 520 120 420 560 150 1040 S -120 1380 -260 1460";
const LEFT_CLIP = "M -560 -420 L 640 -420 C 520 120 420 560 150 1040 S -120 1380 -260 1460 L -560 1460 Z";
const RIGHT_CLIP = "M 640 -420 L 2260 -420 L 2260 1460 L -260 1460 S -120 1380 150 1040 C 420 560 520 120 640 -420 Z";

function catmull(points, steps = 16) {
  const out = [];
  for (let i = 0; i < points.length - 1; i += 1) {
    const p0 = points[Math.max(0, i - 1)], p1 = points[i], p2 = points[i + 1], p3 = points[Math.min(points.length - 1, i + 2)];
    for (let s = 0; s < steps; s += 1) {
      const t = s / steps, t2 = t * t, t3 = t2 * t;
      const f = (k) => 0.5 * (2 * p1[k] + (-p0[k] + p2[k]) * t + (2 * p0[k] - 5 * p1[k] + 4 * p2[k] - p3[k]) * t2 + (-p0[k] + 3 * p1[k] - 3 * p2[k] + p3[k]) * t3);
      out.push([f(0), f(1)]);
    }
  }
  out.push(points[points.length - 1]);
  return out;
}

function offset(line, d) {
  return line.map((p, i) => {
    const a = line[Math.max(0, i - 1)], b = line[Math.min(line.length - 1, i + 1)];
    const len = dist(a, b) || 1;
    const nx = -(b[1] - a[1]) / len, ny = (b[0] - a[0]) / len;
    return [p[0] + nx * d, p[1] + ny * d];
  });
}

const FREEWAY = catmull([[2000, -260], [1800, -60], [1650, 80], [1490, 205], [1360, 375], [1292, 560], [1305, 760], [1372, 940], [1430, 1150], [1470, 1460]]);
const CARRIAGE_A = offset(FREEWAY, 8); // one carriageway
const CARRIAGE_B = offset(FREEWAY, -8).reverse(); // the other, running the other way

function minorRight() {
  let d = "";
  for (const x of XS) if (!ART_X.includes(x)) d += `M ${x} -420 V 1460 `;
  for (const y of YS) if (!ART_Y.includes(y)) d += `M -560 ${y} H 2260 `;
  return d.trim();
}

function minorLeft() {
  const th = (-32 * Math.PI) / 180, c = [150, 520], s = 64;
  const d1 = [Math.cos(th), Math.sin(th)], d2 = [-Math.sin(th), Math.cos(th)];
  let d = "";
  for (let k = -20; k <= 20; k += 1) {
    for (const [u, v] of [[d1, d2], [d2, d1]]) {
      const o = [c[0] + v[0] * k * s, c[1] + v[1] * k * s];
      const a = [o[0] - u[0] * 1800, o[1] - u[1] * 1800], b = [o[0] + u[0] * 1800, o[1] + u[1] * 1800];
      d += `M ${P(a)} L ${P(b)} `;
    }
  }
  return d.trim();
}

function arterials() {
  let d = "";
  for (const x of ART_X) d += `M ${x} -420 V 1460 `;
  for (const y of ART_Y) d += `M -560 ${y} H 2260 `;
  d += "M -100 1180 L 2260 104 "; // the long diagonal avenue
  return d.trim();
}

const city = `<g id="city">
  <rect class="m-land" x="-600" y="-460" width="2900" height="1960"/>
  <path class="m-park-band" d="${RIVER}"/>
  <rect class="m-park" x="1116" y="416" width="73" height="78" rx="4"/>
  <rect class="m-park" x="486" y="680" width="84" height="84" rx="4"/>
  <path class="m-park" d="M 170 300 L 262 242 L 300 302 L 208 360 Z"/>
  <rect class="m-park" x="1660" y="420" width="160" height="164" rx="4"/>
  <rect class="m-park" x="1110" y="-112" width="80" height="76" rx="4"/>
  <g clip-path="url(#clip-left)"><path class="m-road" d="${minorLeft()}"/></g>
  <g clip-path="url(#clip-right)"><path class="m-road" d="${minorRight()}"/></g>
  <path class="m-water" d="${RIVER}"/>
  <path class="m-major-case" d="${arterials()}"/>
  <path class="m-major" d="${arterials()}"/>
  <path class="m-fwy-case" d="${poly(CARRIAGE_A)} ${poly(CARRIAGE_B)}"/>
  <path class="m-fwy" d="${poly(CARRIAGE_A)} ${poly(CARRIAGE_B)}"/>
  <text class="m-label" x="190" y="600" transform="rotate(-32 190 600)">OLD TOWN</text>
  <text class="m-label" x="1150" y="132">MILL DISTRICT</text>
  <text class="m-label" x="-60" y="1250" transform="rotate(-52 -60 1250)">RIVERSIDE</text>
  <text class="m-label m-label-s" x="1153" y="459" text-anchor="middle">PARK</text>
</g>`;

const defs = `<svg class="map-defs" width="0" height="0" aria-hidden="true" focusable="false">
  <defs>
    <clipPath id="clip-left"><path d="${LEFT_CLIP}"/></clipPath>
    <clipPath id="clip-right"><path d="${RIGHT_CLIP}"/></clipPath>
    <g id="chev"><path class="ch-u" d="M -6 -6.6 L 6 0 L -6 6.6"/><path class="ch-o" d="M -6 -6.6 L 6 0 L -6 6.6"/></g>
    ${city}
  </defs>
</svg>`;

// ------------------------------------------------------------- coverage
// An edge: from a to b, its state before the drive and after it, the direction of an earlier
// one-way pass (dir0: "ab" or "ba"), and for the frequency layer a bin 1 to 5.
function chevron(at, angle, extra = "") {
  return `<g class="ch ${extra}" transform="translate(${P(at)}) rotate(${r1(angle)})"><g class="ch-s"><use href="#chev"/></g></g>`;
}

function edgeChevrons(k, line, dirAngle, isNew) {
  // One mark in the middle for one direction, two facing away from each other for both.
  const total = line.reduce((s, p, i) => (i ? s + dist(line[i - 1], p) : 0), 0);
  let walked = 0, mid = line[0], ang = dirAngle;
  for (let i = 1; i < line.length; i += 1) {
    const seg = dist(line[i - 1], line[i]);
    if (walked + seg >= total / 2) {
      mid = lerp(line[i - 1], line[i], (total / 2 - walked) / seg);
      ang = deg(line[i - 1], line[i]);
      break;
    }
    walked += seg;
  }
  const rad = (ang * Math.PI) / 180, o = 11.4;
  const fwd = [mid[0] + Math.cos(rad) * o, mid[1] + Math.sin(rad) * o];
  const back = [mid[0] - Math.cos(rad) * o, mid[1] - Math.sin(rad) * o];
  return [
    chevron(mid, dirAngle === null ? ang : dirAngle, `e-${k} c-one${isNew ? " is-new" : ""}`),
    chevron(fwd, ang, `e-${k} c-both${isNew ? " is-new" : ""}`),
    chevron(back, ang + 180, `e-${k} c-both${isNew ? " is-new" : ""}`),
  ].join("");
}

function coverage(edges, { prefix }) {
  const L = { case: [], line: [], stripe: [], ch: [] };
  edges.forEach((e, i) => {
    const k = `${prefix}${i}`;
    const line = e.line || [e.a, e.b];
    const d = poly(line);
    const state = `s-${e.after}`;
    const bin = e.bin ? ` h${e.bin}` : "";
    const data = e.order !== undefined
      ? ` data-k="${k}" data-before="${e.before}" data-after="${e.after}" data-order="${e.order}"`
      : "";
    const fresh = e.order !== undefined ? " is-new" : "";
    L.case.push(`<path class="cv-case e-${k} ${state}${bin}${fresh}" d="${d}"${data}/>`);
    L.line.push(`<path class="cv-line e-${k} ${state}${bin}${fresh}" d="${d}"/>`);
    L.stripe.push(`<path class="cv-stripe e-${k} ${state}${bin}${fresh}" d="${d}"/>`);
    // Direction of the single mark: an earlier pass keeps its own direction.
    const along = deg(line[0], line[1]);
    const oneAngle = e.dir0 === "ba" ? along + 180 : along;
    L.ch.push(edgeChevrons(k, line, e.after === "pair" ? along : oneAngle, !!fresh).replace(/class="ch /g, `class="ch ${state} `));
  });
  return `<g class="cv-layer">${L.case.join("")}</g><g class="cv-layer">${L.line.join("")}</g><g class="cv-layer">${L.stripe.join("")}</g><g class="cv-layer cv-marks">${L.ch.join("")}</g>`;
}

const seg = (axis, fixed, from, to, rest) => {
  // Split a straight run along grid nodes into one edge per block.
  const nodes = (axis === "x" ? YS : XS).filter((v) => v >= Math.min(from, to) && v <= Math.max(from, to));
  if (from > to) nodes.reverse();
  const out = [];
  for (let i = 0; i < nodes.length - 1; i += 1) {
    const a = axis === "x" ? [fixed, nodes[i]] : [nodes[i], fixed];
    const b = axis === "x" ? [fixed, nodes[i + 1]] : [nodes[i + 1], fixed];
    out.push({ a, b, ...rest });
  }
  return out;
};

// Earlier drives, unchanged by the drive in the hero.
const HERO_OLD = [
  ...seg("y", 330, 1110, 1020, { before: "one", after: "one" }),
  ...seg("y", 235, 750, 1110, { before: "both", after: "both" }),
  ...seg("x", 1110, 675, 410, { before: "one", after: "one" }),
  ...seg("y", 675, 1020, 1195, { before: "one", after: "one" }),
  ...seg("x", 1195, 150, 330, { before: "one", after: "one", dir0: "ab" }),
  { line: CARRIAGE_A.slice(62, 86), before: "pair", after: "pair" },
  { line: CARRIAGE_B.slice(CARRIAGE_B.length - 86, CARRIAGE_B.length - 62), before: "pair", after: "pair" },
];

// The drive: a loop that comes back over two blocks, so those two turn green.
const ROUTE = [[750, 675], [750, 500], [930, 500], [930, 330], [1020, 330], [1020, 410], [930, 410], [930, 500], [845, 500], [845, 675]];
const HERO_NEW = [
  { a: [750, 675], b: [750, 590], before: "none", after: "one", order: 0 },
  { a: [750, 590], b: [750, 500], before: "none", after: "one", order: 1 },
  { a: [750, 500], b: [845, 500], before: "none", after: "one", order: 2 },
  { a: [845, 500], b: [930, 500], before: "none", after: "both", order: 3 },
  { a: [930, 500], b: [930, 410], before: "none", after: "both", order: 4 },
  { a: [930, 410], b: [930, 330], before: "none", after: "one", order: 5 },
  // Driven westbound before (dir0 "ba"), eastbound now: both directions.
  { a: [930, 330], b: [1020, 330], before: "one", after: "both", dir0: "ba", order: 6 },
  { a: [1020, 330], b: [1020, 410], before: "none", after: "one", order: 7 },
  { a: [1020, 410], b: [930, 410], before: "none", after: "one", order: 8 },
  { a: [845, 500], b: [845, 590], before: "none", after: "one", order: 9 },
  { a: [845, 590], b: [845, 675], before: "none", after: "one", order: 10 },
];
// The old westbound pass on 1110 to 1020 keeps its direction.
HERO_OLD[0].dir0 = "ab";

function trailMarks(route, spacing = 64) {
  const out = [];
  let walked = 0, next = spacing * 0.75;
  for (let i = 1; i < route.length; i += 1) {
    const a = route[i - 1], b = route[i], s = dist(a, b);
    while (next <= walked + s) {
      const p = lerp(a, b, (next - walked) / s);
      out.push(`<g class="tm" data-at="${r1(next)}" transform="translate(${P(p)}) rotate(${r1(deg(a, b))})"><g class="ch-s"><use href="#chev"/></g></g>`);
      next += spacing;
    }
    walked += s;
  }
  return { marks: out.join(""), length: walked };
}

const trail = trailMarks(ROUTE);
const end = ROUTE[ROUTE.length - 1];
const hero = `<svg class="map hero-map" viewBox="-500 -350 2700 1750" preserveAspectRatio="xMinYMin meet" aria-hidden="true" focusable="false">
  <use href="#city"/>
  <g class="cv-old">${coverage(HERO_OLD, { prefix: "o" })}</g>
  <g class="cv-new">${coverage(HERO_NEW, { prefix: "n" })}</g>
  <g class="trail">
    <path class="tr-glow" d="${poly(ROUTE)}"/>
    <path class="tr-case" d="${poly(ROUTE)}"/>
    <path class="tr-line" id="route" d="${poly(ROUTE)}" data-length="${r1(trail.length)}"/>
    <g class="tr-marks">${trail.marks}</g>
  </g>
  <g class="puck" transform="translate(${P(end)})">
    <g class="puck-s">
      <circle class="puck-acc" r="24"/>
      <circle class="puck-ring" r="11"/>
      <circle class="puck-dot" r="7.5"/>
      <g class="puck-head"><path class="puck-arrow" d="M 0 -7.5 L 5.6 5.6 L 0 2.6 L -5.6 5.6 Z"/></g>
    </g>
  </g>
</svg>`;

// --------------------------------------------------------- the road layers card
const ROADS = [
  ...seg("y", 235, 1020, 1195, { before: "both", after: "both", bin: 3 }),
  ...seg("x", 1110, 235, 410, { before: "one", after: "one", bin: 1 }),
  ...seg("y", 410, 1110, 1290, { before: "one", after: "one", bin: 1 }),
  ...seg("x", 1195, 410, 590, { before: "one", after: "one", bin: 2, dir0: "ab" }),
  ...seg("y", 500, 1020, 1110, { before: "both", after: "both", bin: 2 }),
  ...seg("x", 1020, 235, 500, { before: "one", after: "one", bin: 1, dir0: "ab" }),
  { line: CARRIAGE_A.slice(58, 88), before: "pair", after: "pair", bin: 5 },
  { line: CARRIAGE_B.slice(CARRIAGE_B.length - 88, CARRIAGE_B.length - 58), before: "pair", after: "pair", bin: 4 },
];
const roadsMap = `<svg class="map mini-map roads-map" viewBox="960 150 600 400" preserveAspectRatio="xMidYMid slice" aria-hidden="true" focusable="false">
  <use href="#city"/>
  ${coverage(ROADS, { prefix: "r" })}
</svg>`;

// ------------------------------------------------------------ the gap card
const RUN_A = [[400, 860], [575, 860], [750, 860]];
const RUN_B = [[1020, 770], [1195, 770], [1195, 590]];
const FILL = [[750, 860], [845, 860], [845, 770], [1020, 770]];
const gapMap = `<svg class="map mini-map gap-map" viewBox="560 520 700 420" preserveAspectRatio="xMidYMid slice" aria-hidden="true" focusable="false">
  <use href="#city"/>
  <path class="gap-line" d="${poly([RUN_A[RUN_A.length - 1], RUN_B[0]])}"/>
  <path class="gap-fill" d="${poly(FILL)}"/>
  <path class="run-case" d="${poly(RUN_A)} ${poly(RUN_B)}"/>
  <path class="run-line" d="${poly(RUN_A)} ${poly(RUN_B)}"/>
</svg>`;

// ------------------------------------------------------------ the plan card
const PLAN_OLD = [
  ...seg("y", 235, 660, 1110, { before: "both", after: "both" }),
  ...seg("x", 660, 60, 410, { before: "one", after: "one" }),
  ...seg("y", 410, 930, 1110, { before: "one", after: "one", dir0: "ab" }),
];
const LOOP = [[845, 410], [750, 410], [750, 150], [1020, 150], [1020, 330], [845, 330], [845, 410]];
const WAYPOINTS = [[750, 150], [1020, 150], [1020, 330]];
const planMap = `<svg class="map mini-map plan-map" viewBox="600 60 560 400" preserveAspectRatio="xMidYMid slice" aria-hidden="true" focusable="false">
  <use href="#city"/>
  ${coverage(PLAN_OLD, { prefix: "p" })}
  <path class="rt-case" d="${poly(LOOP)}"/>
  <path class="rt-line" d="${poly(LOOP)}"/>
  ${WAYPOINTS.map((p, i) => `<g class="wp" transform="translate(${P(p)})"><circle r="10"/><text y="4" text-anchor="middle">${i + 1}</text></g>`).join("")}
  <g class="puck puck-idle" transform="translate(845 410)"><g class="puck-s"><circle class="puck-ring" r="11"/><circle class="puck-dot" r="7.5"/></g></g>
</svg>`;

// ---------------------------------------------------------- the street card
const STREET_DONE = [[620, 590], [930, 590]];
const STREET_OPEN = [[930, 590], [1290, 590], [1560, 590]];
const streetMap = `<svg class="map mini-map street-map" viewBox="700 440 600 480" preserveAspectRatio="xMidYMid slice" aria-hidden="true" focusable="false">
  <use href="#city"/>
  <path class="st-case" d="${poly([STREET_DONE[0], STREET_OPEN[STREET_OPEN.length - 1]])}"/>
  <path class="st-open" d="${poly(STREET_OPEN)}"/>
  <path class="st-done" d="${poly(STREET_DONE)}"/>
  <g class="puck puck-idle" transform="translate(890 535)"><g class="puck-s"><circle class="puck-ring" r="11"/><circle class="puck-dot" r="7.5"/></g></g>
</svg>`;

let html = fs.readFileSync(path.join(HERE, "index.src.html"), "utf8");
const parts = { DEFS: defs, HERO_MAP: hero, ROADS_MAP: roadsMap, GAP_MAP: gapMap, PLAN_MAP: planMap, STREET_MAP: streetMap };
for (const [k, v] of Object.entries(parts)) {
  if (!html.includes(`{{${k}}}`)) throw new Error(`missing {{${k}}}`);
  html = html.replace(`{{${k}}}`, v);
}
if (/\{\{[A-Z_]+\}\}/.test(html)) throw new Error("unfilled placeholder");
fs.writeFileSync(OUT, html);
console.log("wrote", OUT, html.length, "bytes; route length", r1(trail.length));
