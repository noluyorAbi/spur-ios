#!/bin/bash
# Cost of one live refresh (SPEC 17.3, review L2) against trip length: a synthetic motion.bin of
# 10 min, 1 h, 4 h and 8 h at 100 Hz, MotionAnalyzer.live through the mapped reader (the read
# included), compiled with -O for the Mac. Prints the refresh time, the cadence the estimator's
# policy gives (max(10 s, 50 times the refresh)) and the share of one core it costs. A phone is
# about 3 to 5 times slower than the Mac; the policy measures the phone's own time.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/bench
swiftc -O -D DEBUG -swift-version 6 -o build/bench/motion-bench \
  Spur/Domain/Model/LatLon.swift Spur/Domain/Model/Fix.swift Spur/Domain/Motion/MotionFile.swift \
  Spur/Domain/Motion/MotionAnalysis.swift Spur/Domain/Motion/MotionSynth.swift Spur/Domain/Export/MotionExport.swift \
  Spur/Domain/Export/Num.swift tools/motion-bench/main.swift tools/motion-bench/Stubs.swift
for HOURS in 0.1666667 1 4 8; do
  FILE=build/bench/live-$HOURS-h.bin
  build/bench/motion-bench gen "$FILE" "$HOURS" >/dev/null
  echo "$HOURS h: $(build/bench/motion-bench live "$FILE")"
  rm -f "$FILE" "$FILE.fixes.json"
done
