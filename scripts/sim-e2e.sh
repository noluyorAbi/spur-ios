#!/usr/bin/env bash
# Simulator end-to-end check (SPEC section 11.2). Prints PASS or FAIL per check.
#
# 1. Build, install, grant "location always".
# 2. Launch with -SpurAutoStart YES, drive a synthetic 15 km route (45 waypoints, 25 m/s, 1 s).
# 3. After 20 s send Spur to the background for 60 s, then bring it back.
# 4. Terminate Spur mid-trip, wait 10 s, relaunch without autostart, wait 30 s.
# 5. Read the fix file from the app container and check gaps, resume and fix count.
# 6. Capture screenshots into docs/screenshots/ (skip with SPUR_E2E_SKIP_SCREENSHOTS=1).
#
# Environment: SPUR_SIM (device name, default "iPhone 17 Pro").
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DEVICE_NAME="${SPUR_SIM:-iPhone 17 Pro}"
OUT="$ROOT/.orchestra/tmp/e2e"
DERIVED="$ROOT/build/dd"
mkdir -p "$OUT"
FAILS=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if "iOS-26" not in runtime:
        continue
    for d in devices:
        if d["name"] == name:
            print(d["udid"]); sys.exit(0)
' "$DEVICE_NAME")
if [[ -z "$UDID" ]]; then
  fail "no iOS 26 simulator named $DEVICE_NAME"
  exit 1
fi
echo "simulator: $DEVICE_NAME $UDID"

# 1. Build and install.
if xcodegen generate >"$OUT/xcodegen.log" 2>&1; then pass "xcodegen generate"; else fail "xcodegen generate (see $OUT/xcodegen.log)"; exit 1; fi
if xcodebuild -project Spur.xcodeproj -scheme Spur -configuration Debug \
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED" build >"$OUT/build.log" 2>&1; then
  pass "xcodebuild build for the simulator"
else
  fail "xcodebuild build (see $OUT/build.log)"; exit 1
fi
APP="$DERIVED/Build/Products/Debug-iphonesimulator/Spur.app"
BID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Info.plist")
echo "bundle id: $BID"

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" "$BID" >/dev/null 2>&1 || true
if xcrun simctl install "$UDID" "$APP"; then pass "install"; else fail "install"; exit 1; fi
if xcrun simctl privacy "$UDID" grant location-always "$BID"; then pass "grant location-always"; else fail "grant location-always"; fi
# SPEC 16.3: the simulator has no motion hardware; the Debug synthetic source derives motion from
# the fixes. Stored in the app's defaults, so the relaunches (also iOS's own) keep it.
xcrun simctl spawn "$UDID" defaults write "$BID" SpurSynthMotion -bool YES
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 >/dev/null 2>&1 || true

# A synthetic route: 45 waypoints, about 15 km, a gentle S curve north of downtown Dallas.
WAYPOINTS=$(python3 -I -c '
import math
lat, lon = 32.7767, -96.7970
pts = [(lat, lon)]
R = 6371008.8
for k in range(1, 45):
    bearing = math.radians(20 + 25 * math.sin(k / 7.0))
    d = 345.0
    lat1, lon1 = math.radians(lat), math.radians(lon)
    lat2 = math.asin(math.sin(lat1) * math.cos(d / R) + math.cos(lat1) * math.sin(d / R) * math.cos(bearing))
    lon2 = lon1 + math.atan2(math.sin(bearing) * math.sin(d / R) * math.cos(lat1), math.cos(d / R) - math.sin(lat1) * math.sin(lat2))
    lat, lon = math.degrees(lat2), math.degrees(lon2)
    pts.append((lat, lon))
print(" ".join(f"{a:.6f},{b:.6f}" for a, b in pts))
')
COUNT=$(echo "$WAYPOINTS" | wc -w | tr -d ' ')
echo "route: $COUNT waypoints"

# 2. Launch with autostart, then drive.
xcrun simctl location "$UDID" set 32.776700,-96.797000 >/dev/null
xcrun simctl launch "$UDID" "$BID" -SpurAutoStart YES >/dev/null
sleep 4
# shellcheck disable=SC2086
xcrun simctl location "$UDID" start --speed=25 --interval=1 $WAYPOINTS >/dev/null
ROUTE_START=$(now_ms)
echo "route started"

# 3. Background for 60 s after 20 s of driving.
sleep 20
BG_START=$(now_ms)
xcrun simctl launch "$UDID" com.apple.Preferences >/dev/null
sleep 60
BG_END=$(now_ms)
xcrun simctl launch "$UDID" "$BID" >/dev/null
echo "back in the foreground"
sleep 5

# 4. Terminate mid-trip, relaunch without autostart.
KILL=$(now_ms)
xcrun simctl terminate "$UDID" "$BID" >/dev/null
sleep 10
xcrun simctl launch "$UDID" "$BID" >/dev/null
RELAUNCH=$(now_ms)
echo "relaunched"
sleep 30
END=$(now_ms)

# Screenshot of the live recording while the route still runs.
if [[ "${SPUR_E2E_SKIP_SCREENSHOTS:-0}" != "1" ]]; then
  mkdir -p "$ROOT/docs/screenshots"
  SHOT="$ROOT/docs/screenshots/1-live-recording"
  xcrun simctl io "$UDID" screenshot "$SHOT.png" >/dev/null 2>&1 \
    && python3 -I "$ROOT/scripts/clean_image.py" "$SHOT.png" "$SHOT.jpg" \
    && pass "screenshot live recording ($SHOT.jpg)" || fail "screenshot live recording"
fi

# 5. Read the data.
CONTAINER=$(xcrun simctl get_app_container "$UDID" "$BID" data)
TRIPS="$CONTAINER/Library/Application Support/Spur/Trips"
rm -rf "$OUT/trips"
cp -R "$TRIPS" "$OUT/trips" 2>/dev/null || true
if python3 -I "$ROOT/scripts/e2e_check.py" "$TRIPS" "$ROUTE_START" "$BG_START" "$BG_END" "$KILL" "$RELAUNCH" "$END"; then
  :
else
  FAILS=$((FAILS + 1))
fi
xcrun simctl location "$UDID" clear >/dev/null 2>&1 || true

# 5b. Motion (SPEC 16.3.3): stop the trip through a Debug relaunch, wait for its analysis, check
# the samples against the fixes and the alignment.
xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
xcrun simctl launch "$UDID" "$BID" -SpurStopRecording YES >/dev/null
TRIP_DIR=$(ls -d "$TRIPS"/*/ | head -1)
for _ in $(seq 1 90); do
  python3 -I -c "import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get('motion') else 1)" "$TRIP_DIR/trip.json" 2>/dev/null && break
  sleep 1
done
if python3 -I "$ROOT/scripts/motion_check.py" "$TRIP_DIR" --aligned; then :; else FAILS=$((FAILS + 1)); fi
xcrun simctl spawn "$UDID" defaults delete "$BID" SpurSynthMotion >/dev/null 2>&1 || true

# 6. Screenshots of every screen (seed data, detail, settings, permission denied).
if [[ "${SPUR_E2E_SKIP_SCREENSHOTS:-0}" != "1" && -x "$ROOT/scripts/screenshots.sh" ]]; then
  if "$ROOT/scripts/screenshots.sh" "$UDID" "$APP" "$BID"; then :; else FAILS=$((FAILS + 1)); fi
fi

echo
if [[ $FAILS -eq 0 ]]; then
  echo "RESULT: PASS (all checks)"
  exit 0
fi
echo "RESULT: FAIL ($FAILS failing)"
exit 1
