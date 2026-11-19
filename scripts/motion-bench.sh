#!/bin/bash
# Time and memory of the motion analysis in release mode (SPEC 16.3.2 step 10, review item 9):
# an 8 hour file at 100 Hz (2.88 million samples) must analyze in a few seconds and stay under
# 200 MB of footprint; the sensor CSV export too. Compiles the analysis with -O (and the
# Debug-only synthetic generator) for the Mac and runs each step in its own process.
set -euo pipefail
cd "$(dirname "$0")/.."
HOURS="${1:-8}"
LIMIT_MB=200
mkdir -p build/bench
swiftc -O -D DEBUG -swift-version 6 -o build/bench/motion-bench \
  Spur/Domain/Model/LatLon.swift Spur/Domain/Model/Fix.swift Spur/Domain/Motion/MotionFile.swift \
  Spur/Domain/Motion/MotionAnalysis.swift Spur/Domain/Motion/MotionSynth.swift Spur/Domain/Export/MotionExport.swift \
  Spur/Domain/Export/Num.swift tools/motion-bench/main.swift tools/motion-bench/Stubs.swift
FILE=build/bench/motion-$HOURS-h.bin
build/bench/motion-bench gen "$FILE" "$HOURS"
FAIL=0
for step in analyze csv; do
  OUT=$(build/bench/motion-bench $step "$FILE")
  echo "$OUT"
  PEAK=$(echo "$OUT" | sed -E 's/.*footprint peak ([0-9]+) MB.*/\1/')
  if [ "$PEAK" -lt "$LIMIT_MB" ]; then echo "PASS: $step footprint peak $PEAK MB under $LIMIT_MB MB"; else echo "FAIL: $step footprint peak $PEAK MB"; FAIL=1; fi
done
rm -f "$FILE" "$FILE.fixes.json"
exit $FAIL
