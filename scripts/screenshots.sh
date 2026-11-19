#!/usr/bin/env bash
# Captures the screens of SPEC 11.2 step 6 into docs/screenshots/ with synthetic demo data.
# Usage: scripts/screenshots.sh <udid> <app path> <bundle id>
# The live recording screenshot (1-live-recording.png) is taken by sim-e2e.sh during the drive.
set -uo pipefail
UDID="$1"; APP="$2"; BID="$3"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHOTS="$ROOT/docs/screenshots"
mkdir -p "$SHOTS"
FAILS=0

shot() {
  local name="$1"; shift
  xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
  sleep 1
  xcrun simctl launch "$UDID" "$BID" -SpurSeedDemo YES "$@" >/dev/null
  sleep "${WAIT:-6}"
  if xcrun simctl io "$UDID" screenshot "$SHOTS/$name.png" >/dev/null 2>&1 \
      && python3 -I "$ROOT/scripts/clean_image.py" "$SHOTS/$name.png" "$SHOTS/$name.jpg"; then
    echo "PASS: screenshot $name ($SHOTS/$name.jpg)"
  else
    echo "FAIL: screenshot $name"; FAILS=$((FAILS + 1))
  fi
}

# Fresh install, so only the demo trips are present.
xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" "$BID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl privacy "$UDID" grant location-always "$BID"
xcrun simctl location "$UDID" set 32.776700,-96.797000 >/dev/null 2>&1 || true
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 >/dev/null 2>&1 || true

WAIT=10 shot "2-history" -SpurTab history
WAIT=8 shot "3-detail-top" -SpurOpenTrip newest
WAIT=8 shot "4-detail-lower" -SpurOpenTrip newest -SpurDetailScroll stopps
WAIT=8 shot "5-detail-bottom" -SpurOpenTrip newest -SpurDetailScroll orte
WAIT=4 shot "6-settings" -SpurTab settings
WAIT=6 shot "13-settings-roads" -SpurTab settings -SpurSettingsScroll strassendaten
WAIT=5 shot "7-live-ready" -SpurTab live

# Permission denied state.
xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
xcrun simctl privacy "$UDID" revoke location "$BID" >/dev/null 2>&1 || true
WAIT=4 shot "8-permission-denied" -SpurTab live
xcrun simctl privacy "$UDID" grant location-always "$BID" >/dev/null 2>&1 || true

xcrun simctl status_bar "$UDID" clear >/dev/null 2>&1 || true
[[ $FAILS -eq 0 ]]
