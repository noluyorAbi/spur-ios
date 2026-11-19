#!/usr/bin/env bash
# Every unit test, in two passes (the physics and live-estimator tables take minutes in a debug
# build, seconds in an optimized one):
#   1. the whole SpurTests target in Debug except the long table suites;
#   2. those suites in their own optimized build (-O, testability kept), same tests, same
#      assertions, nothing skipped or weakened.
# Prints both "Test run with ..." lines and PHYSICS-IDENTICAL or PHYSICS-DIFF against
# docs/motion-physics-table.txt. Exit 0 only when both passes pass and the table is identical.
#
# Usage: scripts/test-all.sh <simulator udid>
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
UDID="${1:?usage: scripts/test-all.sh <simulator udid>}"
OUT="$ROOT/.orchestra/tmp/test-all"
mkdir -p "$OUT"
LONG=(LiveMotionTests MotionPhysicsSuiteTests)
SKIP=()
ONLY=()
for s in "${LONG[@]}"; do SKIP+=("-skip-testing:SpurTests/$s"); ONLY+=("-only-testing:SpurTests/$s"); done
FAIL=0

xcodegen generate >/dev/null 2>&1
xcodebuild -project Spur.xcodeproj -scheme Spur -destination "id=$UDID" test "${SKIP[@]}" >"$OUT/debug.log" 2>&1 || FAIL=1
echo "debug pass: $(grep -E "Test run with" "$OUT/debug.log" | tail -1 | sed 's/^[^T]*//')"

xcodebuild -project Spur.xcodeproj -scheme Spur -destination "id=$UDID" -derivedDataPath "$ROOT/build/optimized-tests" \
    SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule ENABLE_TESTABILITY=YES \
    test "${ONLY[@]}" >"$OUT/optimized.log" 2>&1 || FAIL=1
echo "optimized pass (${LONG[*]}): $(grep -E "Test run with" "$OUT/optimized.log" | tail -1 | sed 's/^[^T]*//')"

if grep -o "PHYSICS [^J].*" "$OUT/optimized.log" | grep -v JOLTSEED | sort | diff -q - <(grep "^PHYSICS" docs/motion-physics-table.txt | sort) >/dev/null; then
  echo "PHYSICS-IDENTICAL"
else
  echo "PHYSICS-DIFF"
  FAIL=1
fi
grep -E "recorded an issue" "$OUT/debug.log" "$OUT/optimized.log" | head -5
exit $FAIL
