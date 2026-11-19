#!/usr/bin/env bash
# Motion end to end with speed changes (SPEC 16.3.3): Apple's recorded "Freeway Drive" in the
# simulator for 150 s, with the Debug synthetic motion source; the trip is stopped through a Debug relaunch and its analysis must
# be aligned with r_long >= 0.9 and a maximum deceleration matching the GPS. sim-e2e drives at
# constant speed, where only the lateral can align.
#
# Usage: scripts/motion-e2e.sh [udid]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UDID="${1:-}"
[[ -n "$UDID" ]] || { echo "FAIL: pass the simulator UDID (scripts/motion-e2e.sh <udid>)"; exit 1; }
APP="$ROOT/build/dd/Build/Products/Debug-iphonesimulator/Spur.app"
[[ -d "$APP" ]] || { echo "FAIL: build the app first ($APP missing)"; exit 1; }
BID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Info.plist")

xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" "$BID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl privacy "$UDID" grant location-always "$BID" >/dev/null
xcrun simctl spawn "$UDID" defaults write "$BID" SpurSynthMotion -bool YES
# Apple's recorded "Freeway Drive" scenario: real speed changes and curves (simctl's own start
# command moves at one speed per call, which gives step changes no car makes).
xcrun simctl location "$UDID" set 37.3318,-122.0312 >/dev/null
xcrun simctl launch "$UDID" "$BID" -SpurAutoStart YES >/dev/null
sleep 5
xcrun simctl location "$UDID" run "Freeway Drive" >/dev/null
sleep "${SPUR_MOTION_E2E_SECONDS:-150}"
xcrun simctl location "$UDID" clear >/dev/null
sleep 3

xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
xcrun simctl launch "$UDID" "$BID" -SpurStopRecording YES >/dev/null
CONTAINER=$(xcrun simctl get_app_container "$UDID" "$BID" data)
TRIP_DIR=$(ls -d "$CONTAINER/Library/Application Support/Spur/Trips"/*/ | head -1)
for _ in $(seq 1 90); do
  python3 -I -c "import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get('motion') else 1)" "$TRIP_DIR/trip.json" 2>/dev/null && break
  sleep 1
done
FAILS=0
python3 -I "$ROOT/scripts/motion_check.py" "$TRIP_DIR" --long || FAILS=1
xcrun simctl spawn "$UDID" defaults delete "$BID" SpurSynthMotion >/dev/null 2>&1 || true
xcrun simctl location "$UDID" clear >/dev/null 2>&1 || true
xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
[[ $FAILS == 0 ]] && echo "RESULT: PASS (all checks)" || echo "RESULT: FAIL"
exit $FAILS
