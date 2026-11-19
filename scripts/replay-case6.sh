#!/usr/bin/env bash
# SPEC 14.8: replays the parent's case 6 (downtown grid, 60 s at a red light) through the real
# engine and the real UI, and checks the stored trip against the oracle.
#
#   - installs the Debug app with the parent's downtown fixture as its road pack
#     (`-SpurRoadFixture`, no bundled pack, no cache, no network);
#   - runs the XCUITest Case6ReplayTests, which presses Start, waits until the trip passed the
#     route's last signal and holds the stop ring;
#   - meanwhile drives the oracle's noise-free route with `simctl location start` in three legs:
#     to the red light at 11 m/s, 60 s standing (creeping the few meters to the next sample at
#     about 0.13 m/s, below the 1 m/s stop speed), onwards at 11 m/s until just past
#     the last signal, then the last few meters of the route at 2 m/s (still moving, so holding the
#     stop ring there adds no stop);
#   - checks the stored trip: one stop, classified at a signal, and the signal sites of the oracle.
#
# Usage: scripts/replay-case6.sh [simulator udid]. Prints PASS or FAIL per check.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/.orchestra/tmp/replay-case6"
DERIVED="$ROOT/build/dd"
ORACLE="$ROOT/SpurTests/Fixtures/oracle/oracle-case6.json"
FIXTURE="$ROOT/SpurTests/Fixtures/osm/downtown-grid.json"
rm -rf "$OUT"
mkdir -p "$OUT"
FAILS=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }

UDID="${1:-$(xcrun simctl list devices available -j | python3 -c '
import json, sys
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if "iOS-26" in runtime:
        for d in devices:
            if d["name"] == "iPhone 17 Pro":
                print(d["udid"]); sys.exit(0)
')}"
[[ -n "$UDID" ]] || { fail "no simulator"; exit 1; }

# The route legs, the expected values and the distance at which the test stops, from the oracle.
python3 -I - "$ORACLE" "$OUT" <<'PY' || { echo "FAIL: route from the oracle"; exit 1; }
import json, math, sys
oracle, out = sys.argv[1], sys.argv[2]
d = json.load(open(oracle))
c6 = d["case6"]
samples = [s for s in c6["samples"] if not s["standing"]]
stop_m = c6["stopAtM"]
def hav(a, b):
    r = 6371008.8
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp, dl = p2 - p1, math.radians(b[1] - a[1])
    x = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(min(1, math.sqrt(x)))
before = [(s["lat"], s["lon"]) for s in samples if s["m"] < stop_m][::3]
after_all = [s for s in samples if s["m"] > stop_m + 6]
stop_pt = (c6["stopPoint"]["lat"], c6["stopPoint"]["lon"])
creep = next((s["lat"], s["lon"]) for s in after_all)   # the first point about 6 m past the stop line
leg1 = before + [stop_pt]
def length(pts): return sum(hav(pts[i - 1], pts[i]) for i in range(1, len(pts)))
feat = {f["nodeId"]: f for f in d["features"]}
# Signal sites of the true route: consecutive signal passes within 30 m of each other are one site.
sites, last = 0, None
signal_ms = []
for p in d["drives"][0]["passes"]:
    f = feat[p["nodeId"]]
    if f["type"] != "traffic_signals":
        continue
    pos = (f["lat"], f["lon"])
    if last is None or hav(last, pos) > 30:
        sites += 1
    last = pos
    signal_ms.append(p["m"])
route_m = samples[-1]["m"]
past = max(signal_ms) + 8
leg3 = [creep] + [(s["lat"], s["lon"]) for s in after_all if s["m"] < past][3::3]
turn = next(s for s in after_all if s["m"] >= past)
leg3.append((turn["lat"], turn["lon"]))
leg4 = [(s["lat"], s["lon"]) for s in samples if s["m"] >= turn["m"]]
# The HUD distance is the distance statistic: standing (below 1 m/s) adds nothing, so the target is
# the driven polyline up to just past the last signal, minus a small margin for chords at corners.
target_km = (length(leg1) + length(leg3) - 3) / 1000
for name, pts in (("leg1", leg1), ("leg2", [stop_pt, creep]), ("leg3", leg3), ("leg4", leg4)):
    open(f"{out}/{name}.txt", "w").write("\n".join(f"{a:.7f},{b:.7f}" for a, b in pts) + "\n")
info = {"stop_s": c6["stopDurationS"], "leg1_s": length(leg1) / 11, "leg2_m": hav(stop_pt, creep), "leg3_s": length(leg3) / 11, "leg4_m": length(leg4),
        "sites": sites, "target_km": round(target_km, 3), "route_m": route_m, "signal_node": c6["signalNode"],
        "start": f"{leg1[0][0]:.7f},{leg1[0][1]:.7f}"}
json.dump(info, open(f"{out}/route.json", "w"))
print(f"route {route_m:.0f} m, stop at {stop_m:.0f} m for {c6['stopDurationS']} s, last signal at {max(signal_ms):.0f} m, "
      f"oracle signal sites {sites}, the test stops at {target_km:.3f} km of driven distance, then {length(leg4):.0f} m remain at 2 m/s")
if length(leg4) < 20:
    sys.exit("too little route left after the last signal")
PY
INFO="$OUT/route.json"
J() { python3 -I -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$INFO" "$1"; }

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
xcrun simctl privacy "$UDID" grant location "$BID"
xcrun simctl location "$UDID" clear >/dev/null 2>&1 || true
xcrun simctl location "$UDID" set "$(J start)" >/dev/null

TEST_RUNNER_SPUR_REPLAY_TARGET_KM="$(J target_km)" TEST_RUNNER_SPUR_ROAD_FIXTURE="$FIXTURE" xcodebuild -project Spur.xcodeproj -scheme SpurUIFlow \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED" -resultBundlePath "$OUT/replay.xcresult" \
  -only-testing:SpurUITests/Case6ReplayTests test-without-building >"$OUT/test.log" 2>&1 &
TEST_PID=$!

# Drive once Start was pressed (a trip folder that is recording). xcodebuild installs the app again,
# so the data container is looked up on every poll.
STARTED=0
for _ in $(seq 1 240); do
  CONTAINER=$(xcrun simctl get_app_container "$UDID" "$BID" data 2>/dev/null)
  if grep -ls '"isRecording" : true' "$CONTAINER/Library/Application Support/Spur/Trips"/*/trip.json >/dev/null 2>&1; then
    STARTED=1; break
  fi
  sleep 1
done
if [[ $STARTED -eq 1 ]]; then pass "Start pressed in the UI, trip recording"; else fail "no recording trip appeared"; fi
if [[ $STARTED -eq 1 ]]; then
  xcrun simctl location "$UDID" start --speed=11 --interval=1 - < "$OUT/leg1.txt" >/dev/null
  sleep "$(python3 -c "print(round($(J leg1_s) + 2))")"
  CREEP=$(python3 -c "print(round($(J leg2_m) / $(J stop_s), 4))")
  xcrun simctl location "$UDID" start --speed="$CREEP" --interval=1 - < "$OUT/leg2.txt" >/dev/null
  sleep "$(python3 -c "print(round($(J stop_s) + 1))")"
  xcrun simctl location "$UDID" start --speed=11 --interval=1 - < "$OUT/leg3.txt" >/dev/null
  sleep "$(python3 -c "print(round($(J leg3_s) + 1))")"
  xcrun simctl location "$UDID" start --speed=2 --interval=1 - < "$OUT/leg4.txt" >/dev/null
  pass "route driven with simctl location start: $(wc -l < "$OUT/leg1.txt" | tr -d ' ') waypoints to the red light, $(J stop_s) s standing at $CREEP m/s, $(wc -l < "$OUT/leg3.txt" | tr -d ' ') waypoints past the last signal, $(python3 -c "print(round($(J leg4_m)))") m at 2 m/s"
fi
if wait "$TEST_PID"; then
  pass "UI: Start, drive to $(J target_km) km, hold to stop, stop summary, detail ($(grep -E "Executed 1 test" "$OUT/test.log" | tail -1 | sed 's/^ *//'))"
else
  fail "UI replay test (see $OUT/test.log)"
  grep -E "error:|XCTAssert|failed" "$OUT/test.log" | head -10
fi
xcrun simctl location "$UDID" clear >/dev/null 2>&1 || true

# Screenshots the test attached.
if xcrun xcresulttool export attachments --path "$OUT/replay.xcresult" --output-path "$OUT/attachments" >/dev/null 2>&1; then
  python3 -I - "$OUT/attachments" "$ROOT" <<'PY'
import json, os, subprocess, sys
folder, root = sys.argv[1], sys.argv[2]
manifest = json.load(open(os.path.join(folder, "manifest.json")))
wanted = {"replay-live": "11-live-road-layer", "replay-roads": "12-detail-roads", "replay-detail": "14-replay-detail-map"}
for test in manifest:
    for a in test.get("attachments", []):
        name = a.get("suggestedHumanReadableName", "")
        for key, target in wanted.items():
            if name.startswith(key + "_") or name.startswith(key + "."):
                src = os.path.join(folder, a["exportedFileName"])
                png = os.path.join(root, "docs/screenshots", target + ".png")
                subprocess.run(["sips", "-s", "format", "png", src, "--out", png], check=True, capture_output=True)
                subprocess.run(["python3", "-I", os.path.join(root, "scripts/clean_image.py"), png,
                                os.path.join(root, "docs/screenshots", target + ".jpg")], check=True)
                print(f"PASS: screenshot docs/screenshots/{target}.jpg")
PY
else
  fail "could not export the replay screenshots"
fi

# The stored trip against the oracle (the analysis runs off the main actor right after Stop).
CONTAINER=$(xcrun simctl get_app_container "$UDID" "$BID" data)
python3 -I - "$CONTAINER" "$INFO" <<'PY' || FAILS=$((FAILS + 1))
import json, os, sys, time
container, info = sys.argv[1], json.load(open(sys.argv[2]))
trips = os.path.join(container, "Library/Application Support/Spur/Trips")
failures = 0
def check(ok, text):
    global failures
    print(("PASS: " if ok else "FAIL: ") + text)
    failures += 0 if ok else 1
record = None
for _ in range(60):
    records = [json.load(open(os.path.join(trips, d, "trip.json"))) for d in os.listdir(trips)]
    done = [r for r in records if not r.get("isDemo") and not r.get("isRecording")]
    if done and done[0].get("roads"):
        record = done[0]
        break
    time.sleep(1)
check(record is not None, "the recorded trip is finished and has its roads block")
if record:
    roads, stats = record["roads"], record["statistics"]
    fixes = sum(1 for l in open(os.path.join(trips, record["id"], "fixes.jsonl")) if '"t"' in l and '"type"' not in l)
    check(fixes > 100, f"{fixes} fixes recorded through the real engine, {stats['distance']:.0f} m")
    check(stats["stops"]["count"] == 1, f"exactly one stop: {stats['stops']['count']} (longest {stats['stops']['longest']:.0f} s)")
    s = roads["stops"]
    check(s == {"signal": 1, "stopSign": 0, "other": 0}, f"stop classified at a signal: {s}")
    got, want = roads["counts"]["signalSites"], info["sites"]
    check(got == want, f"signal sites passed {got}, oracle {want}")
    check(roads.get("tilesFromPack", 0) >= 1, f"road data from the fixture as pack: {roads.get('tilesFromPack')} tiles, coverage {roads.get('coverage', 0):.3f}")
    details = json.load(open(os.path.join(trips, record["id"], "roads.json")))
    nodes = [p["nodeId"] for p in details["passed"]]
    check(info["signal_node"] in nodes, f"roads.json lists the red light's signal node {info['signal_node']} among {len(nodes)} passed features")
sys.exit(1 if failures else 0)
PY
rm -rf "$OUT/replay.xcresult"

# SPEC 16.3.3: the replayed trip's motion (synthetic source): samples against the fixes and its
# analysis. The case 6 drive has little excitation (constant speed legs), so its alignment is
# reported, and asserted by sim-e2e.
MOTION_TRIP=$(python3 -I -c "
import json, os, sys
t = os.path.join(sys.argv[1], 'Library/Application Support/Spur/Trips')
for d in os.listdir(t):
    r = json.load(open(os.path.join(t, d, 'trip.json')))
    if not r.get('isDemo') and not r.get('isRecording'):
        print(os.path.join(t, d)); break" "$CONTAINER")
if python3 -I "$ROOT/scripts/motion_check.py" "$MOTION_TRIP" --analysis; then :; else FAILS=$((FAILS + 1)); fi
python3 -I "$ROOT/scripts/motion_check.py" "$MOTION_TRIP" --aligned | sed -E 's/^(PASS|FAIL): /INFO (alignment, not asserted here): /' | tail -2

echo
# SPEC 16.2: the speed limit sign on the fixture's North Ervay Street (way 9978059, 30 mph): 10 s at
# 12 m/s, 12 s at 20 m/s (more than 5 mph over), 8 s at 10 m/s (red clears), then no fixes (the sign
# goes). The UI test moves the simulated position itself.
LIMIT_ROUTE=$(python3 -I - "$FIXTURE" <<'PY'
import json, math, sys
e = json.load(open(sys.argv[1]))["elements"]
nodes = {x["id"]: (x["lat"], x["lon"]) for x in e if x["type"] == "node"}
way = next(x for x in e if x["type"] == "way" and x["id"] == 9978059)
pts = [nodes[n] for n in way["nodes"] if n in nodes]
R = 6371008.8
def dist(a, b):
    p1, p2 = math.radians(a[0]), math.radians(b[0]); dl = math.radians(b[1] - a[1]); dp = p2 - p1
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * R * math.asin(math.sqrt(h))
def bearing(a, b):
    p1, p2 = math.radians(a[0]), math.radians(b[0]); dl = math.radians(b[1] - a[1])
    return (math.degrees(math.atan2(math.sin(dl) * math.cos(p2), math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl))) + 360) % 360
cum = [0.0]
for a, b in zip(pts, pts[1:]): cum.append(cum[-1] + dist(a, b))
out, d, k = [], 0.0, 0
while d <= cum[-1]:
    i = max(j for j in range(len(cum) - 1) if cum[j] <= d)
    t = (d - cum[i]) / max(1e-9, cum[i + 1] - cum[i])
    a, b = pts[i], pts[i + 1]
    speed = 12.0 if k < 10 else (20.0 if k < 22 else 10.0)
    out.append(f"{a[0] + (b[0] - a[0]) * t:.7f},{a[1] + (b[1] - a[1]) * t:.7f},{bearing(a, b):.1f},{speed}")
    d += speed; k += 1
print(";".join(out))
PY
)
xcrun simctl location "$UDID" clear >/dev/null 2>&1 || true
if TEST_RUNNER_SPUR_ROAD_FIXTURE="$FIXTURE" TEST_RUNNER_SPUR_LIMIT_ROUTE="$LIMIT_ROUTE" xcodebuild -project Spur.xcodeproj -scheme SpurUIFlow \
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED" -resultBundlePath "$OUT/limit.xcresult" \
    -only-testing:SpurUITests/SpeedLimitSignTests test-without-building >"$OUT/limit.log" 2>&1; then
  pass "speed limit: $(grep -o 'SPEED LIMIT labels: .*' "$OUT/limit.log" | head -1) ($(grep -E "Executed 1 test" "$OUT/limit.log" | tail -1 | sed 's/^ *//'))"
  if xcrun xcresulttool export attachments --path "$OUT/limit.xcresult" --output-path "$OUT/limit-attachments" >/dev/null 2>&1; then
    python3 -I - "$OUT/limit-attachments" "$ROOT" <<'PY'
import json, os, subprocess, sys
folder, root = sys.argv[1], sys.argv[2]
for test in json.load(open(os.path.join(folder, "manifest.json"))):
    for a in test.get("attachments", []):
        name = a.get("suggestedHumanReadableName", "")
        for key, target in {"speed-limit-over": "17-speed-limit-over", "speed-limit": "16-speed-limit"}.items():
            if name.startswith(key + "_") or name.startswith(key + "."):
                src = os.path.join(folder, a["exportedFileName"])
                png = os.path.join(root, "docs/screenshots", target + ".png")
                subprocess.run(["sips", "-s", "format", "png", src, "--out", png], check=True, capture_output=True)
                subprocess.run(["python3", "-I", os.path.join(root, "scripts/clean_image.py"), png,
                                os.path.join(root, "docs/screenshots", target + ".jpg")], check=True)
                print(f"PASS: screenshot docs/screenshots/{target}.jpg")
                break
PY
  fi
else
  fail "speed limit UI test (see $OUT/limit.log)"
  grep -E "error:|SPEED LIMIT" "$OUT/limit.log" | sed 's/.*error: -\[[^]]*\] : //' | head -6
fi
xcrun simctl location "$UDID" clear >/dev/null 2>&1 || true

if [[ $FAILS -eq 0 ]]; then echo "RESULT: PASS (all checks)"; exit 0; fi
echo "RESULT: FAIL ($FAILS failing)"; exit 1
