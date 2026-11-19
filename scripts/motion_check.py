#!/usr/bin/env python3
"""Checks a trip's motion data (SPEC 16.3.3 e2e). Usage: motion_check.py <trip folder> [--analysis] [--aligned] [--long]

- motion.bin exists, its header is format 1 with 60-byte records, no truncated tail;
- the sample count is the rate times the time the fixes cover (pairs at most 5 s apart), within 5 %;
- with --analysis: trip.json has a motion block whose sample count matches the file;
- with --long: as --aligned, but r_long itself must be at least 0.9 (a drive with speed changes);
- with --aligned: the analysis is aligned with r >= 0.9 (r_long, or r_lat when the speed never
  changes and r_long is undefined), and the largest deceleration matches the
  largest drop between consecutive fixes (dt <= 2 s) within 0.5 m/s².
"""
import json, os, struct, sys

failures = 0
def report(ok, text):
    global failures
    print(("PASS: " if ok else "FAIL: ") + text)
    failures += 0 if ok else 1

folder = sys.argv[1]
flags = set(sys.argv[2:])
path = os.path.join(folder, "motion.bin")
report(os.path.exists(path), "motion.bin exists")
if not os.path.exists(path):
    sys.exit(1)
data = open(path, "rb").read()
magic, version, size, rate, frame = data[:8], *struct.unpack_from("<HHHB", data, 8)
count, tail = divmod(len(data) - 32, size)
report(magic == b"SPURMOT\0" and version == 1 and size == 60 and tail == 0,
       f"header magic {magic!r}, version {version}, record {size} B, rate {rate} Hz, {count} samples, {tail} trailing bytes")
fixes = []
for line in open(os.path.join(folder, "fixes.jsonl"), "rb"):
    try:
        o = json.loads(line)
    except json.JSONDecodeError:
        continue
    if "t" in o and "type" not in o:
        fixes.append(o)
covered = sum((b["t"] - a["t"]) / 1000 for a, b in zip(fixes, fixes[1:]) if 0 < b["t"] - a["t"] <= 5000)
expected = rate * covered
report(expected > 0 and abs(count - expected) <= 0.05 * expected,
       f"{count} samples for {covered:.0f} s covered by fixes at {rate} Hz (expected {expected:.0f} +- 5 %)")
if "--long" in flags:
    flags.add("--aligned")
if "--analysis" in flags or "--aligned" in flags:
    trip = json.load(open(os.path.join(folder, "trip.json")))
    m = trip.get("motion")
    report(m is not None and m.get("sampleCount") == count, f"trip.json motion block: {json.dumps(m)[:400] if m else None}")
    if m and "--aligned" in flags:
        # r_long needs speed changes; on a constant-speed drive it is undefined and the lateral fit
        # (gyro times GPS speed in the turns) carries the alignment.
        r = m.get("rLong") if m.get("rLong") is not None else m.get("rLat")
        if "--long" in flags:
            # SPEC 16.3.3 literally: aligned with r_long >= 0.9 (a drive with speed changes).
            r = m.get("rLong")
        report(m.get("alignedSegments", 0) >= 1 and (r or 0) >= 0.9,
               f"aligned segments {m.get('alignedSegments')}, r_long {m.get('rLong')}, r_lat {m.get('rLat')}, r_fit {m.get('rFit')}, lag {m.get('lagSeconds')} s")
        drops = [((b.get("spd") or 0) - (a.get("spd") or 0)) / ((b["t"] - a["t"]) / 1000)
                 for a, b in zip(fixes, fixes[1:]) if 0 < b["t"] - a["t"] <= 2000 and a.get("spd") is not None and b.get("spd") is not None]
        gps = min(drops) if drops else 0
        got = m.get("maxBraking") or 0
        report(abs(got - gps) <= 0.5, f"max deceleration {got:.2f} m/s², GPS {gps:.2f} m/s²")
sys.exit(1 if failures else 0)
