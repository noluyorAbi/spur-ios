#!/usr/bin/env bash
# Real UI flow (end to end through the UI, not launch arguments): runs SpurUITests, which taps
# Start, drives 45 s, holds the stop ring, opens the trip from the stop summary, exports it,
# checks the history totals, exports all trips as ZIP and checks the "bereits gefahren" layer.
# Then this script checks what the flow left in the app container. Prints PASS or FAIL per check.
#
# Usage: scripts/ui-flow.sh [simulator udid]   (default: the iPhone 17 Pro on iOS 26)
# SPUR_SHOT_SUFFIX=-iphone16 appends that to the screenshot names (a second device size).
# SPUR_MAP_STYLE=light|dark runs the flow in that Kartenstil (SPEC 18.1); default Automatisch.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/.orchestra/tmp/ui-flow"
DERIVED="$ROOT/build/dd"
# The parent web app (not public), for its parsers and scripts: SPUR_PARENT, else the path in
# Config/Local.parent (gitignored); without either the parent steps are skipped.
PARENT="${SPUR_PARENT:-$(cat "$(cd "$(dirname "$0")/.." && pwd)/Config/Local.parent" 2>/dev/null || true)}"
rm -rf "$OUT"
mkdir -p "$OUT"
FAILS=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }

export TEST_RUNNER_SPUR_MAP_STYLE="${SPUR_MAP_STYLE:-}"
UDID="${1:-$(xcrun simctl list devices available -j | python3 -c '
import json, sys
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if "iOS-26" in runtime:
        for d in devices:
            if d["name"] == "iPhone 17 Pro":
                print(d["udid"]); sys.exit(0)
')}"
[[ -n "$UDID" ]] || { fail "no simulator"; exit 1; }

xcodegen generate >"$OUT/xcodegen.log" 2>&1 || { fail "xcodegen"; exit 1; }
if xcodebuild -project Spur.xcodeproj -scheme SpurUIFlow -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath "$DERIVED" build-for-testing >"$OUT/build.log" 2>&1; then
  pass "build for testing"
else
  fail "build for testing (see $OUT/build.log)"; exit 1
fi
APP="$DERIVED/Build/Products/Debug-iphonesimulator/Spur.app"
BID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Info.plist")

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" "$BID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"
# Plain "location" (when in use): what a first-run user grants at the first Start.
xcrun simctl privacy "$UDID" grant location "$BID"
xcrun simctl location "$UDID" clear >/dev/null 2>&1 || true

if xcodebuild -project Spur.xcodeproj -scheme SpurUIFlow -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath "$DERIVED" -resultBundlePath "$OUT/flow.xcresult" -only-testing:SpurUITests/RealTripFlowTests \
    test-without-building >"$OUT/test.log" 2>&1; then
  pass "UI flow (when-in-use permission): Start, Pause and Fortsetzen, 45 s drive, 0.4 s press keeps recording, 2 s hold stops, summary, detail, export, history totals 5, ZIP, driven layer 5 ($(grep -E "Executed 1 test" "$OUT/test.log" | tail -1 | sed 's/^ *//'))"
else
  fail "UI flow (see $OUT/test.log)"
  grep -E "error:|XCTAssert|failed" "$OUT/test.log" | head -10
fi

# The live view's round buttons react on their whole circle and the map still takes drags.
xcrun simctl location "$UDID" clear >/dev/null 2>&1 || true
if xcodebuild -project Spur.xcodeproj -scheme SpurUIFlow -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath "$DERIVED" -only-testing:SpurUITests/LiveButtonsTests \
    test-without-building >"$OUT/buttons.log" 2>&1; then
  pass "live buttons: taps 15 pt off the glyph register on layer.roads, layer.driven and Zentrieren, a drag reaches the map, the layer menu switches to Satellit and Häufigkeit and back, traffic on and off ($(grep -E "Executed 1 test" "$OUT/buttons.log" | tail -1 | sed 's/^ *//'))"
else
  fail "live buttons (see $OUT/buttons.log)"
  grep -E "error:" "$OUT/buttons.log" | sed 's/.*error: -\[[^]]*\] : //' | head -10
fi

# SPEC 18.3: search, the place card with its driving time, the route on the live map.
xcrun simctl location "$UDID" set 32.7767,-96.7970 >/dev/null 2>&1 || true
if xcodebuild -project Spur.xcodeproj -scheme SpurUIFlow -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath "$DERIVED" -resultBundlePath "$OUT/plan.xcresult" -only-testing:SpurUITests/PlanSearchTests -only-testing:SpurUITests/ExploreTests -only-testing:SpurUITests/DiscoveryRouteTests -only-testing:SpurUITests/GapFillUITests -only-testing:SpurUITests/AutoPauseUITests -only-testing:SpurUITests/StreetSearchUITests \
    test-without-building >"$OUT/plan.log" 2>&1; then
  pass "Planen: search, place card with km and driving time, Navigieren offered, route shown on the Fahrt tab; Entdecken finds scenarios on the Dallas pack, a result opens its card, the nearest undriven stretch; an Entdeckerroute is planned, shown on the live map and kept there while a recording runs; a gap fill is accepted, undone and rejected; a simulated break pauses the trip and driving on resumes it; a street is found by name, shown with its driven share, and the way to its undriven part opens the place card ($(grep -E "Executed [0-9]+ tests?" "$OUT/plan.log" | tail -1 | sed 's/^ *//'))"
  if xcrun xcresulttool export attachments --path "$OUT/plan.xcresult" --output-path "$OUT/plan-attachments" >/dev/null 2>&1; then
    python3 -I - "$OUT/plan-attachments" "$ROOT" <<'PY'
import json, os, subprocess, sys
folder, root = sys.argv[1], sys.argv[2]
suffix = os.environ.get("SPUR_SHOT_SUFFIX", "")
wanted = {"place-card": "34-plan-place-card", "route-on-live": "35-plan-route-on-live",
          "explore-results": "36-explore-results", "explore-card": "37-explore-card",
          "route-card": "38-route-card", "route-live": "39-route-on-live",
          "gap-suggestion": "40-gap-suggestion", "gap-accepted": "41-gap-accepted",
          "route-recording": "42-route-recording", "auto-paused": "43-auto-paused",
          "street-nearby": "44-street-nearby", "street-card": "45-street-card", "street-go": "46-street-go"}
for test in json.load(open(os.path.join(folder, "manifest.json"))):
    for a in test.get("attachments", []):
        name = a.get("suggestedHumanReadableName", "")
        for key, out in wanted.items():
            if name.startswith(key):
                dst = os.path.join(root, "docs", "screenshots", out + suffix + ".jpg")
                subprocess.run(["python3", "-I", os.path.join(root, "scripts", "clean_image.py"), os.path.join(folder, a["exportedFileName"]), dst], check=False)
                print("PASS: screenshot " + os.path.relpath(dst, root))
PY
  fi
else
  fail "Planen (see $OUT/plan.log)"
fi

# Screenshots the flow attached: the stop summary and the driven layer after the trip.
if xcrun xcresulttool export attachments --path "$OUT/flow.xcresult" --output-path "$OUT/attachments" >/dev/null 2>&1; then
  python3 -I - "$OUT/attachments" "$ROOT" <<'PY'
import json, os, subprocess, sys
folder, root = sys.argv[1], sys.argv[2]
suffix = os.environ.get("SPUR_SHOT_SUFFIX", "")
manifest = json.load(open(os.path.join(folder, "manifest.json")))
wanted = {"summary": "9-real-trip-stop-summary", "driven-layer": "10-real-trip-driven-layer",
          "panel-medium": "24-live-panel-medium", "paused": "33-live-paused", "panel-large": "25-live-panel-large",
          "panel-unaligned": "26-live-panel-unaligned", "running-details": "27-running-trip-details"}
for test in manifest:
    for a in test.get("attachments", []):
        name = a.get("suggestedHumanReadableName", "")
        for key, target in wanted.items():
            if name.startswith(key + "_") or name.startswith(key + "."):
                src = os.path.join(folder, a["exportedFileName"])
                target = target + suffix
                png = os.path.join(root, "docs/screenshots", target + ".png")
                subprocess.run(["sips", "-s", "format", "png", src, "--out", png], check=True, capture_output=True)
                subprocess.run(["python3", "-I", os.path.join(root, "scripts/clean_image.py"), png,
                                os.path.join(root, "docs/screenshots", target + ".jpg")], check=True)
                print(f"PASS: screenshot docs/screenshots/{target}.jpg")
PY
else
  fail "could not export the flow screenshots"
fi

# What the flow left behind.
CONTAINER=$(xcrun simctl get_app_container "$UDID" "$BID" data)
python3 -I - "$CONTAINER" <<'PY' || FAILS=$((FAILS + 1))
import csv, io, json, os, re, subprocess, sys
container = sys.argv[1]
trips_dir = os.path.join(container, "Library/Application Support/Spur/Trips")
exports = os.path.join(container, "Documents/Exports")
failures = 0
def check(ok, text):
    global failures
    print(("PASS: " if ok else "FAIL: ") + text)
    failures += 0 if ok else 1

records = []
for d in os.listdir(trips_dir):
    with open(os.path.join(trips_dir, d, "trip.json"), encoding="utf-8") as fh:
        records.append(json.load(fh))
# The Planen tests run after the export checks: the gap fill test seeds its own trip, and the
# route test records a short one after the ZIP was written. Neither is part of the ZIP.
records = [r for r in records if r.get("note") != "Demofahrt mit Lücke"]
zip_names = sorted(f for f in os.listdir(exports) if f.startswith("spur-alle-fahrten-") and f.endswith(".zip"))
if zip_names:
    zip_stamp = zip_names[0][len("spur-alle-fahrten-"):-len("Z.zip")]
    records = [r for r in records if r["startedAt"][:19].replace(":", "") <= zip_stamp]
real = [r for r in records if not r.get("isDemo")]
check(len(real) == 1, f"one recorded (non-demo) trip next to {len(records) - len(real)} demo trips")
r = real[0]
fixes = [json.loads(l) for l in open(os.path.join(trips_dir, r["id"], "fixes.jsonl"), encoding="utf-8")
         if l.strip() and '"t"' in l and '"type"' not in l]
dist = (r.get("statistics") or {}).get("distance", 0)
check(r.get("isRecording") is False and r.get("endedAt"), f"trip {r['id'][:8]} finished via hold to stop, ended {r.get('endedAt')}")
check(len(fixes) >= 30, f"{len(fixes)} fixes recorded through the real engine")
check(dist > 300, f"statistics distance {dist:.0f} m")
check(bool(r.get("preview")), f"preview lines for the driven layer: {len(r.get('preview') or [])}")

stamp = r["startedAt"][:19].replace(":", "") + "Z"
stem = "spur-" + stamp
files = {ext: os.path.join(exports, f"{stem}.{ext}") for ext in ["gpx", "csv", "geojson", "json"]}
check(all(os.path.exists(p) for p in files.values()), f"export of the recorded trip in Documents/Exports: {stem}.gpx/.csv/.geojson/.json")
rows = list(csv.reader(open(files["csv"], encoding="utf-8")))
check(len(rows) - 1 == len(fixes), f"CSV has {len(rows) - 1} rows for {len(fixes)} fixes")
gpx = open(files["gpx"], encoding="utf-8").read()
check(gpx.count("<trkpt ") == len(fixes), f"GPX has {gpx.count('<trkpt ')} track points")
geo = json.load(open(files["geojson"], encoding="utf-8"))
check(geo.get("type") == "FeatureCollection" and geo["features"], f"GeoJSON parses, {len(geo['features'])} features")
doc = json.load(open(files["json"], encoding="utf-8"))
check(doc["trip"]["id"] == r["id"], "JSON export carries the trip")

zips = sorted(f for f in os.listdir(exports) if f.startswith("spur-alle-fahrten-") and f.endswith(".zip"))
check(len(zips) == 1, f"all-trips ZIP: {zips}")
listing = subprocess.run(["unzip", "-l", os.path.join(exports, zips[0])], capture_output=True, text=True).stdout
check(f"{stem}/{stem}.csv" in listing and "trips.csv" in listing, "ZIP holds the recorded trip's folder and trips.csv")
entries = len(re.findall(r"/spur-[0-9T-]+Z(-[0-9a-f]+)?\.(gpx|csv|geojson|json)$", listing, re.M))
check(entries == 4 * len(records), f"ZIP holds {entries} trip files for {len(records)} trips")
summary = subprocess.run(["unzip", "-p", os.path.join(exports, zips[0]), "*/trips.csv"], capture_output=True, text=True).stdout
check(len(summary.strip().splitlines()) - 1 == len(records), f"trips.csv has {len(summary.strip().splitlines()) - 1} rows")
open(os.environ.get("TMPDIR", "/tmp") + "/spur-ui-flow-files.txt", "w").write(f"{files['csv']}\n{files['gpx']}\n{len(fixes)}\n")
sys.exit(1 if failures else 0)
PY

# The parent's own parsers on the recorded trip's export (scratch script outside both repos).
LIST="${TMPDIR:-/tmp}/spur-ui-flow-files.txt"
if [[ -z "$PARENT" || ! -d "$PARENT" ]]; then
  echo "SKIP: parent parsers not available (set SPUR_PARENT)"
  rm -f "$LIST"
elif [[ -f "$LIST" ]] && command -v bun >/dev/null; then
  CSV=$(sed -n 1p "$LIST"); GPX=$(sed -n 2p "$LIST"); N=$(sed -n 3p "$LIST")
  SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/spur-ui-flow.XXXXXX")
  cp "$CSV" "$SCRATCH/trip.csv"; cp "$GPX" "$SCRATCH/trip.gpx"
  cat > "$SCRATCH/check.ts" <<TS
import { readFileSync } from "node:fs";
import { parseCsv } from "$PARENT/src/lib/capture/csv.ts";
import { parseGpx } from "$PARENT/src/lib/capture/gpx.ts";
console.log(parseCsv(readFileSync("$SCRATCH/trip.csv", "utf8")).length, parseGpx(readFileSync("$SCRATCH/trip.gpx", "utf8")).length);
TS
  read -r PC PG <<<"$(cd "$SCRATCH" && bun run check.ts 2>/dev/null | tail -1)"
  if [[ "$PC" == "$N" && "$PG" == "$N" ]]; then
    pass "parent parsers read the recorded trip: CSV $PC, GPX $PG of $N fixes"
  else
    fail "parent parsers: CSV ${PC:-?}, GPX ${PG:-?} of $N fixes"
  fi
  rm -rf "$SCRATCH" "$LIST"
fi
rm -rf "$OUT/flow.xcresult"

echo
if [[ $FAILS -eq 0 ]]; then echo "RESULT: PASS (all checks)"; exit 0; fi
echo "RESULT: FAIL ($FAILS failing)"; exit 1
