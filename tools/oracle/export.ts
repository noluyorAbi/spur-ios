/**
 * Oracle export from the parent project (SPEC 14.4). Read only: it imports the parent's own code
 * and test scenarios by absolute path and writes only into this repository.
 *
 *   SPUR_PARENT=/path/to/parent bun run tools/oracle/export.ts
 *
 * Writes, for the nine map-matching cases of the parent (test/matching/scenarios.ts):
 *   SpurTests/Fixtures/osm/<fixture>.json      the OSM fixture, reduced to the elements and tags
 *                                              Spur reads (checked below to give the parent the
 *                                              same features, segments and categories)
 *   SpurTests/Fixtures/oracle/oracle-case<N>.json
 *       features    every feature node of the parent's extractFeatures(segmentWays(elements)),
 *                   with the skew flag and approach angles of every junction
 *       segments    segment ids and lengths of the parent's segmenter
 *       categories  the parent's categoriesFor per kept way
 *       maxspeed    the parent's parseMaxspeedMph per distinct maxspeed tag
 *       drives      the pooled drives of the case: synthetic fixes, the ground-truth route legs and
 *                   the feature nodes passed in travel order, derived from the route legs
 *       case 6      the noise-free samples and the stop point of the 60 s red light
 *
 * Road data © OpenStreetMap contributors, ODbL.
 */
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

const PARENT = process.env.SPUR_PARENT;
if (!PARENT) throw new Error("set SPUR_PARENT to the parent web app's checkout");
const OUT = join(dirname(new URL(import.meta.url).pathname), "..", "..", "SpurTests", "Fixtures");

const scenarios = await import(`${PARENT}/test/matching/scenarios.ts`);
const fixtures = await import(`${PARENT}/test/matching/helpers/fixtures.ts`);
const { extractFeatures } = await import(`${PARENT}/src/lib/osm/features.ts`);
const { segmentWays } = await import(`${PARENT}/src/lib/osm/segment.ts`);
const { categoriesFor } = await import(`${PARENT}/src/lib/osm/categories.ts`);
const { parseMaxspeedMph } = await import(`${PARENT}/src/lib/osm/maxspeed.ts`);
const { isKeptRoad } = await import(`${PARENT}/src/lib/osm/tags.ts`);
const { generateTrack } = await import(`${PARENT}/test/matching/helpers/track.ts`);
const { destination, haversineM, bearingDeg } = await import(`${PARENT}/src/lib/geo.ts`);

/** Extra seeds per drive for the robustness sweep (not part of the acceptance table). */
const SWEEP_SEEDS = Array.from({ length: 10 }, (_, k) => k + 1);
/** Lane offset for cases 1 to 4: the true path moved this far to the right of the OSM centreline. */
const LANE_OFFSET_M = 7;

const compact = (fixes: any[]): any[] =>
  fixes.map((f: any) => ({
    t: f.t,
    lat: round(f.lat, 8),
    lon: round(f.lon, 8),
    accuracy: f.accuracy,
    speed: f.speed === null ? null : round(f.speed, 3),
    heading: f.heading === null ? null : round(f.heading, 2),
  }));

/** The path moved `offsetM` to the right of the direction of travel, with fresh route distances. */
function shiftRight(path: any[], offsetM: number): any[] {
  const out: any[] = [];
  for (let i = 0; i < path.length; i++) {
    const a = path[Math.max(0, i - 1)]!;
    const b = path[Math.min(path.length - 1, i + 1)]!;
    const bearing = i === 0 ? bearingDeg(path[0], path[1]) : i === path.length - 1 ? bearingDeg(path[i - 1], path[i]) : bearingDeg(a, b);
    const p = destination(path[i], (bearing + 90) % 360, offsetM);
    const m = out.length === 0 ? 0 : out[out.length - 1].m + haversineM(out[out.length - 1], p);
    out.push({ lat: p.lat, lon: p.lon, m });
  }
  return out;
}

const WAY_KEYS = new Set([
  "highway", "ref", "name", "oneway", "toll", "maxspeed", "lanes", "junction", "layer",
  "bridge", "tunnel", "hov", "access", "frontage_road", "lane_markings", "lit", "surface", "service",
]);
const NODE_KEYS = new Set(["highway", "railway", "direction", "stop", "stop:direction", "traffic_signals:direction", "traffic_signals", "crossing"]);

function filterTags(tags: Record<string, string> | undefined, keys: Set<string>): Record<string, string> | undefined {
  if (!tags) return undefined;
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(tags)) if (keys.has(k)) out[k] = v;
  return Object.keys(out).length > 0 ? out : undefined;
}

/** Ways with a highway tag and the nodes they use, plus tagged nodes; only the tags Spur reads. */
function reduce(elements: any[]): any[] {
  const ways = elements.filter((e) => e.type === "way" && e.tags?.highway !== undefined);
  const used = new Set<number>();
  for (const w of ways) for (const id of w.nodes) used.add(id);
  const out: any[] = [];
  for (const e of elements) {
    if (e.type === "node") {
      const tags = filterTags(e.tags, NODE_KEYS);
      if (!used.has(e.id) && !tags) continue;
      const n: any = { type: "node", id: e.id, lat: e.lat, lon: e.lon };
      if (tags) n.tags = tags;
      out.push(n);
    } else if (e.type === "way" && e.tags?.highway !== undefined) {
      const w: any = { type: "way", id: e.id, nodes: e.nodes };
      const tags = filterTags(e.tags, WAY_KEYS);
      if (tags) w.tags = tags;
      out.push(w);
    }
  }
  return out;
}

const same = (a: unknown, b: unknown): boolean => JSON.stringify(a) === JSON.stringify(b);

/** Feature nodes passed by a ground-truth route, in travel order, from its legs. */
function passesOf(route: any, featureIds: Set<number>, samples: any[]): any[] {
  const out: any[] = [];
  let last: number | null = null;
  for (const leg of route.legs) {
    const seg = leg.segment;
    const len = seg.lengthM;
    const ids: number[] = seg.nodeIds;
    const offsets: number[] = seg.cumM.map((c: number) => (leg.direction === "forward" ? c : len - c));
    const order = ids.map((_: number, i: number) => i);
    if (leg.direction === "backward") order.reverse();
    for (const i of order) {
      const off = offsets[i]!;
      const atEntry = off <= 1e-6;
      const atExit = off >= len - 1e-6;
      if (atEntry && leg.enterM > 1e-6) continue;
      if (atExit && leg.exitM < len - 1e-6) continue;
      if (off < leg.enterM - 1e-6 || off > leg.exitM + 1e-6) continue;
      const id = ids[i]!;
      if (id === last) continue;
      last = id;
      if (!featureIds.has(id)) continue;
      const m = leg.startM + (off - leg.enterM);
      const s = samples.find((x: any) => x.m >= m - 1e-6);
      out.push({ nodeId: id, m: round(m, 3), t: s ? s.t : null });
    }
  }
  return out;
}

const round = (x: number, d: number): number => Math.round(x * 10 ** d) / 10 ** d;

mkdirSync(join(OUT, "osm"), { recursive: true });
mkdirSync(join(OUT, "oracle"), { recursive: true });

for (const [k, build] of (scenarios.ALL_CASES as (() => any)[]).entries()) {
  const c = build();
  const original = fixtures.loadFixture(c.fixture).elements as any[];
  const reduced = reduce(original);

  const features = extractFeatures(original, segmentWays(original));
  const segments = segmentWays(original);
  // The reduced fixture must give the parent exactly the same answers.
  if (!same(extractFeatures(reduced, segmentWays(reduced)), features)) throw new Error(`case ${c.caseNo}: reduction changed the features`);
  if (!same(segmentWays(reduced).map((s: any) => [s.id, s.lengthM, s.categories, s.directions]), segments.map((s: any) => [s.id, s.lengthM, s.categories, s.directions]))) {
    throw new Error(`case ${c.caseNo}: reduction changed the segments`);
  }

  const categories: Record<string, string[]> = {};
  const maxspeed: Record<string, number | null> = {};
  for (const e of original) {
    if (e.type !== "way" || !isKeptRoad(e.tags)) continue;
    categories[String(e.id)] = categoriesFor(e.tags ?? {});
    if (e.tags?.maxspeed !== undefined) maxspeed[e.tags.maxspeed] = parseMaxspeedMph(e.tags.maxspeed);
  }

  const featureIds = new Set<number>(features.map((f: any) => f.nodeId));
  const drives = c.drives.map((d: any) => ({
    label: d.label,
    seed: d.seed,
    sigmaM: d.sigmaM,
    fixes: d.track.fixes.map((f: any) => ({ t: f.t, lat: f.lat, lon: f.lon, accuracy: f.accuracy, speed: f.speed, heading: f.heading })),
    legs: d.route
      ? d.route.legs.map((l: any) => ({ segmentId: l.segment.id, wayId: l.segment.wayId, direction: l.direction, enterM: round(l.enterM, 3), exitM: round(l.exitM, 3), startM: round(l.startM, 3), endM: round(l.endM, 3) }))
      : [],
    passes: d.route ? passesOf(d.route, featureIds, d.track.samples) : [],
  }));

  const out: any = {
    attribution: "Road data © OpenStreetMap contributors, ODbL. Exported from the parent's test scenarios by tools/oracle/export.ts.",
    caseNo: c.caseNo,
    fixture: c.fixture,
    features,
    segments: segments.map((s: any) => ({ id: s.id, lengthM: s.lengthM })),
    categories,
    maxspeed,
    drives,
  };
  if (c.caseNo === 6) {
    out.case6 = {
      signalNode: c.signalNode,
      stopAtM: c.stopAtM,
      stopDurationS: c.stopDurationS,
      stopPoint: c.stopPoint,
      samples: c.drive.track.samples.map((s: any) => ({ t: s.t, lat: s.lat, lon: s.lon, m: round(s.m, 3), speed: round(s.speed, 4), heading: round(s.heading, 3), standing: s.standing })),
    };
  }
  // Robustness sweep: the same drives with other noise seeds, and for cases 1 to 4 a drive in an
  // outer lane. Same routes, so the same true passes.
  const sweep = c.drives.map((d: any) => ({
    label: d.label,
    seeds: SWEEP_SEEDS.map((k) => ({ seed: d.seed + k, fixes: compact(generateTrack({ ...d.spec, seed: d.seed + k }).fixes) })),
    lane: c.caseNo <= 4 ? { offsetM: LANE_OFFSET_M, fixes: compact(generateTrack({ ...d.spec, path: shiftRight(d.spec.path, LANE_OFFSET_M) }).fixes) } : null,
  }));
  writeFileSync(join(OUT, "oracle", `oracle-sweep-case${c.caseNo}.json`), JSON.stringify({ attribution: out.attribution, caseNo: c.caseNo, sweep }));
  writeFileSync(join(OUT, "osm", `${c.fixture}.json`), JSON.stringify({ attribution: out.attribution, elements: reduced }));
  writeFileSync(join(OUT, "oracle", `oracle-case${c.caseNo}.json`), JSON.stringify(out));
  const junctions = features.filter((f: any) => f.approachAngles !== undefined);
  console.log(
    `case ${c.caseNo} ${c.fixture}: ${original.length} -> ${reduced.length} elements, ${segments.length} segments, ` +
      `${features.length} features (${junctions.length} junctions, ${junctions.filter((f: any) => f.skewed).length} skewed), ` +
      `${drives.length} drives, ${drives.reduce((n: number, d: any) => n + d.passes.length, 0)} passes`,
  );
  void k;
}
