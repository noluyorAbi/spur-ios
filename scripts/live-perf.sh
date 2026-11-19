#!/usr/bin/env bash
# SPEC 17.4 measurements in the simulator, on a synthetic freeway drive with the motion sensor:
#   main  - main-thread busy share from a 20 s `sample` with the live panel closed, at medium and at
#           large (baseline before 1.3: 12.4 to 13.8 %)
#   (WARM_MIN=n: first drive n minutes online in front to fill the tile cache, then measure with
#    road data from the internet off, so the cached tiles are matched and nothing is downloaded;
#    real trips load their tiles from the cache)
#   bg    - CPU seconds per minute over 10 minutes with the app in the background and the panel left
#           open when it went there (the simulator cannot lock; background is the same scene phase)
#   warm  - only the warm-up (WARM_MIN minutes, default 12), then exit; the cache stays for runs
#           with KEEP_INSTALL=1 (both builds must share the bundle id: the install goes over the
#           old one and keeps its data container)
# Env: KEEP_INSTALL=1 install over the existing app instead of a fresh install; ROADS_OFFLINE=1;
#      PERF_COUNTS=1 print the work counters (debug builds with PerfCounters) over the measured
#      window; PROFILE=1 take a 60 s `sample` at minute 2 and minute 8 of a bg run.
# Usage: scripts/live-perf.sh <simulator udid> <app path> main|bg|warm [minutes]
set -uo pipefail
UDID="$1"; APP="$2"; MODE="$3"; MINUTES="${4:-10}"
BID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Info.plist")
OUT="$(cd "$(dirname "$0")/.." && pwd)/.orchestra/tmp/live-perf"
mkdir -p "$OUT"

start_drive() {
  local panel="$1"
  xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1
  if [[ "${KEEP_INSTALL:-0}" != 1 ]]; then
    xcrun simctl uninstall "$UDID" "$BID" >/dev/null 2>&1
    xcrun simctl install "$UDID" "$APP"
  else
    xcrun simctl install "$UDID" "$APP"
    rm -rf "$(xcrun simctl get_app_container "$UDID" "$BID" data)/Library/Application Support/Spur/Trips"
  fi
  xcrun simctl privacy "$UDID" grant location-always "$BID" >/dev/null 2>&1
  xcrun simctl spawn "$UDID" defaults write "$BID" SpurSynthMotion -bool YES
  xcrun simctl spawn "$UDID" defaults write "$BID" SpurAutoStart -bool YES
  # ROADS_OFFLINE=1: no road data from the internet, so tile downloads (whose timing varies from
  # run to run) do not enter the comparison.
  # Written both ways: values set with `simctl spawn defaults` survive an uninstall (cfprefsd), so
  # an earlier offline run would otherwise leave the next run offline too.
  if [[ "${ROADS_OFFLINE:-0}" == 1 ]]; then
    xcrun simctl spawn "$UDID" defaults write "$BID" settings.roadDataOnline -bool NO
  else
    xcrun simctl spawn "$UDID" defaults write "$BID" settings.roadDataOnline -bool YES
  fi
  local want got
  want=$([[ "${ROADS_OFFLINE:-0}" == 1 ]] && echo 0 || echo 1)
  got=$(xcrun simctl spawn "$UDID" defaults read "$BID" settings.roadDataOnline 2>/dev/null)
  [[ "$got" == "$want" ]] || { echo "INVALID: settings.roadDataOnline reads '$got', wanted $want"; exit 1; }
  if [[ "${PERF_COUNTS:-0}" == 1 ]]; then
    xcrun simctl spawn "$UDID" defaults write "$BID" SpurPerfCounters -bool YES
  else
    xcrun simctl spawn "$UDID" defaults delete "$BID" SpurPerfCounters >/dev/null 2>&1
  fi
  if [[ -n "$panel" ]]; then
    xcrun simctl spawn "$UDID" defaults write "$BID" SpurLiveDetails -string "$panel"
    xcrun simctl spawn "$UDID" defaults write "$BID" SpurLiveDetailsAfter -float 20
  else
    xcrun simctl spawn "$UDID" defaults delete "$BID" SpurLiveDetails >/dev/null 2>&1
  fi
  # A route still running from an earlier start would make `run` a no-op: clear it first.
  xcrun simctl location "$UDID" clear >/dev/null 2>&1
  xcrun simctl location "$UDID" set 37.3318,-122.0312 >/dev/null
  xcrun simctl launch "$UDID" "$BID" >/dev/null
  sleep 2
  xcrun simctl location "$UDID" run "Freeway Drive" >/dev/null
}

# The trip's fixes file must grow, else the drive is not running and the number means nothing.
driving() {
  local c f a b
  c=$(xcrun simctl get_app_container "$UDID" "$BID" data)
  f=$(ls -t "$c"/Library/Application\ Support/Spur/Trips/*/fixes.* 2>/dev/null | head -1)
  [[ -n "$f" ]] || { echo "INVALID: no fixes file"; return 1; }
  a=$(stat -f %z "$f"); sleep 12; b=$(stat -f %z "$f")
  [[ "$b" -gt "$a" ]] || { echo "INVALID: not driving (fixes file not growing)"; return 1; }
}

warm_cache() {
  start_drive ""
  sleep $((${WARM_MIN:-12} * 60))
  xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1
  local c
  c=$(xcrun simctl get_app_container "$UDID" "$BID" data)
  # The warm-up trip goes; a resumed trip would be stopped and analysed inside the measurement.
  rm -rf "$c/Library/Application Support/Spur/Trips"
  local n
  n=$(ls "$c/Library/Application Support/Spur/OSM" 2>/dev/null | wc -l | tr -d ' ')
  echo "warm cache: $n tiles"
  [[ "$n" -ge 10 ]] || { echo "INVALID: the warm-up cached fewer than 10 tiles"; exit 1; }
  KEEP_INSTALL=1
  ROADS_OFFLINE=1
}

counts() {
  cat "$(xcrun simctl get_app_container "$UDID" "$BID" data)/Library/Caches/perf-counts.json" 2>/dev/null || echo '{}'
}

pid_of() { pgrep -f "$(basename "$APP")/$(basename "$APP" .app)" | head -1; }

# Main-thread busy share: 1 - samples waiting in mach_msg (the run loop idling) / all samples.
busy() {
  python3 -I - "$1" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().splitlines()
start = next(i for i, l in enumerate(lines) if re.match(r"\s+\d+ Thread_\d+: Main Thread", l))
total = int(lines[start].split()[0])
idle = 0
for l in lines[start + 1:]:
    if re.match(r"\s{4}\d+ Thread_", l):
        break
    if "mach_msg2_trap" in l or "mach_msg_trap" in l:
        idle += int(re.search(r"(\d+)\s+mach_msg2?_trap", l).group(1))
print(f"{100 * (1 - idle / total):.1f} % busy ({total} samples, {idle} waiting)")
PY
}

if [[ "$MODE" == warm ]]; then warm_cache; exit 0; fi
if [[ -n "${WARM_MIN:-}" ]]; then warm_cache; fi

case "$MODE" in
main)
  for panel in "" medium large; do
    start_drive "$panel"
    sleep 45
    driving || continue
    PID=$(pid_of)
    sample "$PID" 20 -file "$OUT/main-${panel:-closed}.txt" >/dev/null 2>&1
    echo "main thread, panel ${panel:-closed}: $(busy "$OUT/main-${panel:-closed}.txt")"
  done
  ;;
bg)
  start_drive "medium"
  sleep 40
  # To the background with the panel open.
  xcrun simctl launch "$UDID" com.apple.Preferences >/dev/null
  sleep 5
  driving || exit 1
  PID=$(pid_of)
  # `ps` time is M:SS.ss, or H:MM:SS for long runs.
  cpu() { ps -o time= -p "$PID" | python3 -c "
import sys
parts = sys.stdin.read().strip().split(':')
secs = 0.0
for p in parts: secs = secs * 60 + float(p)
print(secs)"; }
  A=$(cpu)
  C0=$(counts)
  if [[ "${PROFILE:-0}" == 1 ]]; then
    sleep 120; sample "$PID" 60 -file "$OUT/bg-min2.txt" >/dev/null 2>&1
    sleep 300; sample "$PID" 60 -file "$OUT/bg-min8.txt" >/dev/null 2>&1
    sleep $((MINUTES * 60 - 540))
  else
    sleep $((MINUTES * 60))
  fi
  B=$(cpu)
  C1=$(counts)
  if [[ "${PERF_COUNTS:-0}" == 1 ]]; then
    python3 -I -c "
import json, sys
a, b = json.loads(sys.argv[1]), json.loads(sys.argv[2])
print('work over the window: ' + ', '.join(f'{k} {b[k] - a.get(k, 0)}' for k in sorted(b) if k != 't') + f' (counts span {b.get(\"t\", 0) - a.get(\"t\", 0)} s)')
" "$C0" "$C1"
  fi
  python3 -c "print(f'background with the panel open: {($B - $A) / $MINUTES:.2f} CPU s per minute over $MINUTES min')"
  ;;
esac
xcrun simctl location "$UDID" clear >/dev/null 2>&1
xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1
