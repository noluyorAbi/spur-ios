#!/usr/bin/env bash
# Parent compatibility check (SPEC section 11.3).
#
# Exports the newest demo trip as CSV and GPX in the simulator (-SpurSeedDemo YES
# -SpurExportDemo YES), then parses both files with the parent web app's own parsers
# (src/lib/capture/csv.ts and gpx.ts in the parent, see SPUR_PARENT) from a scratch script in a
# temporary folder outside both repositories. The parent repository is only read.
# Prints PASS or FAIL with the parsed fix counts.
#
# Usage: scripts/parent-compat.sh <simulator udid>
# The UDID is required: falling back to "the first booted simulator" once installed this app over
# another session's simulator in the middle of its test run.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The parent web app (not public), for its parsers and scripts: SPUR_PARENT, else the path in
# Config/Local.parent (gitignored); without either the parent steps are skipped.
PARENT="${SPUR_PARENT:-$(cat "$(cd "$(dirname "$0")/.." && pwd)/Config/Local.parent" 2>/dev/null || true)}"
[[ -n "$PARENT" && -d "$PARENT" ]] || { echo "SKIP: parent parsers not available (set SPUR_PARENT)"; exit 0; }
UDID="${1:-}"
APP="$ROOT/build/dd/Build/Products/Debug-iphonesimulator/Spur.app"
[[ -n "$UDID" ]] || { echo "FAIL: pass the simulator UDID (scripts/parent-compat.sh <udid>); no fallback to a booted device"; exit 1; }
echo "simulator: $UDID"
[[ -d "$APP" ]] || { echo "FAIL: build the app first ($APP missing)"; exit 1; }
command -v bun >/dev/null || { echo "FAIL: bun not installed"; exit 1; }
BID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Info.plist")

# Fresh install with the synthetic demo trips; the newest one is exported on a second launch.
xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" "$BID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl launch "$UDID" "$BID" -SpurSeedDemo YES >/dev/null
CONTAINER=$(xcrun simctl get_app_container "$UDID" "$BID" data)
# Version 1.2: the newest demo trip carries synthetic motion; wait for its analysis so the GPX
# holds motion waypoints next to the track the parent reads.
for _ in $(seq 1 40); do
  grep -lq '"motion"' "$CONTAINER/Library/Application Support/Spur/Trips/"*/trip.json 2>/dev/null && break
  sleep 2
done
xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
xcrun simctl launch "$UDID" "$BID" -SpurSeedDemo YES -SpurExportDemo YES >/dev/null
sleep 8
EXPORTS="$CONTAINER/Documents/Exports"
CSV=$(ls "$EXPORTS"/*.csv 2>/dev/null | head -1)
GPX=$(ls "$EXPORTS"/*.gpx 2>/dev/null | head -1)
[[ -f "$CSV" && -f "$GPX" ]] || { echo "FAIL: no CSV/GPX export in $EXPORTS"; exit 1; }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/spur-parent-compat.XXXXXX")
cp "$CSV" "$GPX" "$SCRATCH/"
CSV_COPY="$SCRATCH/$(basename "$CSV")"
GPX_COPY="$SCRATCH/$(basename "$GPX")"
# Expected counts from the exported files themselves: CSV data rows and GPX track points.
CSV_ROWS=$(($(grep -c "" "$CSV_COPY") - 1))
GPX_POINTS=$(grep -o "<trkpt " "$GPX_COPY" | wc -l | tr -d ' ')
MOTION_WPTS=$(grep -o "<type>motion\." "$GPX_COPY" | wc -l | tr -d ' ')
# Version 1.4: the same GPX with a pause waypoint and an accepted gap fill route in the exporter's
# format (SPEC 18.8, 18.9); the parent must read exactly the same track points from it.
EXTRA_COPY="$SCRATCH/extra.gpx"
python3 - "$GPX_COPY" "$EXTRA_COPY" <<'PY'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
wpt = ('  <wpt lat="32.7800000" lon="-96.8000000">\n    <time>2026-11-10T12:00:00Z</time>\n    <name>Pause</name>\n'
       '    <desc>2026-11-10T12:00:00Z bis 2026-11-10T12:06:40Z, Motor aus</desc>\n    <type>pause.auto</type>\n  </wpt>\n')
rte = ('  <rte>\n    <name>Ergänzt (Lücke)</name>\n    <type>gapFill</type>\n'
       '    <rtept lat="32.7800000" lon="-96.8000000"></rtept>\n    <rtept lat="32.7810000" lon="-96.8000000"></rtept>\n  </rte>\n')
s = s.replace("  <trk>\n", wpt + "  <trk>\n", 1).replace("</gpx>", rte + "</gpx>", 1)
open(sys.argv[2], "w", encoding="utf-8").write(s)
PY

cat > "$SCRATCH/check.ts" <<TS
import { readFileSync } from "node:fs";
import { parseCsv } from "$PARENT/src/lib/capture/csv.ts";
import { parseGpx } from "$PARENT/src/lib/capture/gpx.ts";

const csv = parseCsv(readFileSync("$CSV_COPY", "utf8"));
const gpx = parseGpx(readFileSync("$GPX_COPY", "utf8"));
const withSpeedCsv = csv.filter((f) => f.speed !== null).length;
const withSpeedGpx = gpx.filter((f) => f.speed !== null).length;
const withAccuracyGpx = gpx.filter((f) => f.accuracy !== null).length;
const sameTimes = csv.length === gpx.length && csv.every((f, i) => f.t === gpx[i]!.t);
const extra = parseGpx(readFileSync("$EXTRA_COPY", "utf8"));
const extraSame = extra.length === gpx.length && extra.every((f, i) => f.t === gpx[i]!.t && f.lat === gpx[i]!.lat);
console.log(JSON.stringify({
  csv: csv.length, gpx: gpx.length, withSpeedCsv, withSpeedGpx, withAccuracyGpx, sameTimes, extra: extra.length, extraSame,
  firstCsv: csv[0], firstGpx: gpx[0],
}));
TS

OUT=$(cd "$SCRATCH" && bun run check.ts 2>&1)
echo "parsed: $OUT"
echo "exported: csv rows $CSV_ROWS, gpx trkpt $GPX_POINTS ($(basename "$CSV"), $(basename "$GPX"))"
FAILS=0
python3 - "$OUT" "$CSV_ROWS" "$GPX_POINTS" "$MOTION_WPTS" <<'PY' || FAILS=1
import json, sys
out, rows, points, motion = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
r = json.loads(out.strip().splitlines()[-1])
ok = True
def check(cond, text):
    global ok
    print(("PASS: " if cond else "FAIL: ") + text)
    ok = ok and cond
check(r["csv"] == rows and rows > 0, f"parent parseCsv read {r['csv']} fixes of {rows} exported rows")
check(r["gpx"] == points and points > 0, f"parent parseGpx read {r['gpx']} fixes of {points} exported track points")
check(r["withSpeedCsv"] == r["csv"], f"CSV speed column read for {r['withSpeedCsv']} fixes")
check(r["withSpeedGpx"] == r["gpx"] and r["withAccuracyGpx"] == r["gpx"], f"GPX extensions speed and accuracy read for {r['withSpeedGpx']} and {r['withAccuracyGpx']} fixes")
check(r["sameTimes"], "CSV and GPX give identical timestamps")
check(motion > 0, f"the GPX carries {motion} motion waypoints (version 1.2) and the parent still reads every track point")
check(r["extraSame"], f"with a pause waypoint and a gap fill route (version 1.4) the parent reads the same {r['extra']} track points")
sys.exit(0 if ok else 1)
PY
rm -rf "$SCRATCH"
exit $FAILS
