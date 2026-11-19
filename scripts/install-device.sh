#!/usr/bin/env bash
# Builds Spur in Release for iPhone and installs it on a paired device.
#
# Usage: scripts/install-device.sh [device]
#   device: identifier, UDID, serial number or name as `xcrun devicectl list devices` shows it.
#           Default: the first paired iPhone (a connected one first).
# Signing: automatic, with the team from Config/Local.xcconfig (-allowProvisioningUpdates).
# Exit codes: 0 installed, 1 build or install failed, 2 no device, 3 device locked.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
LOG_DIR="$ROOT/.orchestra/tmp"
mkdir -p "$LOG_DIR"

"$ROOT/scripts/install-font.sh" >/dev/null 2>&1 || true
xcodegen generate >"$LOG_DIR/install-xcodegen.log" 2>&1 || { echo "FAIL: xcodegen generate (see $LOG_DIR/install-xcodegen.log)"; exit 1; }
echo "building Release for generic/platform=iOS ..."
if ! xcodebuild -project Spur.xcodeproj -scheme Spur -configuration Release -destination 'generic/platform=iOS' \
    -derivedDataPath "$ROOT/build/dd" -allowProvisioningUpdates build >"$LOG_DIR/install-build.log" 2>&1; then
  echo "FAIL: Release build (see $LOG_DIR/install-build.log)"
  grep -E "error:" "$LOG_DIR/install-build.log" | head -5
  exit 1
fi
APP="$ROOT/build/dd/Build/Products/Release-iphoneos/Spur.app"
echo "built: $APP"

DEVICE="${1:-}"
if [[ -z "$DEVICE" ]]; then
  JSON=$(mktemp "${TMPDIR:-/tmp}/spur-devices.XXXXXX")
  xcrun devicectl list devices --json-output "$JSON" >/dev/null 2>&1
  DEVICE=$(python3 -I - "$JSON" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1])).get("result", {}).get("devices", [])
phones = [d for d in devices
          if d.get("hardwareProperties", {}).get("deviceType") == "iPhone"
          and d.get("connectionProperties", {}).get("pairingState") == "paired"]
phones.sort(key=lambda d: d.get("connectionProperties", {}).get("tunnelState") != "connected")
print(phones[0]["identifier"] if phones else "")
PY
)
  rm -f "$JSON"
fi
if [[ -z "$DEVICE" ]]; then
  echo "FAIL: no paired iPhone found. Connect the iPhone by cable once, trust this Mac, then run again."
  exit 2
fi
echo "installing on device $DEVICE ..."
OUT=$(xcrun devicectl device install app --device "$DEVICE" "$APP" 2>&1)
STATUS=$?
echo "$OUT" | tail -5
if [[ $STATUS -eq 0 ]]; then
  echo "PASS: Spur installed on $DEVICE"
  exit 0
fi
if echo "$OUT" | grep -qiE "DeviceLocked|device is locked|passcode|unlock"; then
  echo "BLOCKED: the iPhone is locked. Unlock it (and keep it unlocked), then run scripts/install-device.sh again."
  exit 3
fi
echo "FAIL: install failed (see the output above)"
exit 1
