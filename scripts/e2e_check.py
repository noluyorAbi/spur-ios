#!/usr/bin/env python3
"""Checks the fix file of a simulator end-to-end run (called by scripts/sim-e2e.sh).

Usage: e2e_check.py <trips-dir> <route_start_ms> <bg_start_ms> <bg_end_ms> <kill_ms> <relaunch_ms> <end_ms>
Prints one PASS or FAIL line per check and exits non-zero when any check fails.
"""
import json
import os
import sys


def main() -> int:
    trips_dir = sys.argv[1]
    route_start, bg_start, bg_end, kill, relaunch, end = (int(x) for x in sys.argv[2:8])
    failures = 0

    def report(ok: bool, name: str, detail: str) -> None:
        nonlocal failures
        print(("PASS" if ok else "FAIL") + f": {name} ({detail})")
        if not ok:
            failures += 1

    trips = [d for d in os.listdir(trips_dir) if os.path.isdir(os.path.join(trips_dir, d))] if os.path.isdir(trips_dir) else []
    report(len(trips) == 1, "exactly one trip folder", f"found {len(trips)}")
    if len(trips) != 1:
        return 1
    folder = os.path.join(trips_dir, trips[0])
    with open(os.path.join(folder, "trip.json"), encoding="utf-8") as fh:
        trip = json.load(fh)

    fixes, gaps, header, bad = [], [], None, 0
    with open(os.path.join(folder, "fixes.jsonl"), "rb") as fh:
        for n, raw in enumerate(fh.read().split(b"\n")):
            if not raw.strip():
                continue
            try:
                obj = json.loads(raw)
            except json.JSONDecodeError:
                bad += 1
                continue
            if n == 0 and obj.get("format") == "spur-fixes":
                header = obj
            elif obj.get("type") == "gap":
                gaps.append(obj)
            elif "t" in obj:
                fixes.append(obj)
    report(header is not None and header.get("version") == 1, "fix file header", f"{header}")
    report(bad <= 1, "fix file parses", f"{len(fixes)} fixes, {len(gaps)} gap records, {bad} unparseable lines")

    times = [f["t"] for f in fixes]
    report(times == sorted(times), "fix times increase", f"{len(times)} timestamps")

    # 1. No gap longer than 3 s while the app was in the background.
    worst, pairs = 0.0, 0
    for a, b in zip(times, times[1:]):
        if b > bg_start and a < bg_end:
            pairs += 1
            worst = max(worst, (b - a) / 1000)
    in_bg = [t for t in times if bg_start <= t <= bg_end]
    report(pairs > 0 and worst <= 3.0, "background: no gap longer than 3 s",
           f"{len(in_bg)} fixes in {(bg_end - bg_start) / 1000:.0f} s background window, longest interval {worst:.2f} s")

    # 2. The same trip continued after the relaunch, with a relaunch gap and fixes after it.
    # The gap starts at the last fix before the kill. iOS may relaunch Spur in the background by
    # itself right after the kill (a location event), so the gap can be far shorter than the
    # 10 s until the explicit relaunch; both are a resume of the same trip.
    relaunch_gaps = [g for g in gaps if g.get("reason") == "relaunch" and kill - 3000 <= g["start"] <= kill + 1500]
    report(trip.get("isRecording") is True and trip.get("id") == trips[0], "same trip continues after relaunch",
           f"trip {trips[0][:8]} isRecording={trip.get('isRecording')}")
    if relaunch_gaps:
        g = relaunch_gaps[0]
        who = "iOS relaunched Spur in the background" if g["end"] < relaunch - 1500 else "explicit relaunch"
        detail = f"relaunch gap {(g['end'] - g['start']) / 1000:.3f} s from kill-{(kill - g['start']) / 1000:.1f} s, {who}"
    else:
        detail = f"gap records: {[(g['reason'], round((g['end'] - g['start']) / 1000, 1)) for g in gaps]}"
    report(len(relaunch_gaps) == 1, "relaunch gap recorded", detail)
    after = [t for t in times if relaunch_gaps and t >= relaunch_gaps[0]["end"]]
    report(len(after) >= 20, "fixes continue after the relaunch gap", f"{len(after)} fixes after the gap")
    report(any(g.get("reason") == "relaunch" for g in trip.get("gaps", [])), "relaunch gap in trip.json",
           f"{len(trip.get('gaps', []))} gaps in trip.json")

    # 3. Fix count at least 90 % of the route seconds, minus the terminated window.
    route_fixes = [t for t in times if t >= route_start]
    terminated = (relaunch_gaps[0]["end"] - relaunch_gaps[0]["start"]) / 1000 if relaunch_gaps else (relaunch - kill) / 1000
    route_seconds = (min(end, times[-1] if times else end) - route_start) / 1000
    expected = 0.9 * (route_seconds - terminated)
    report(len(route_fixes) >= expected, "fix count at least 90 % of route seconds minus terminated window",
           f"{len(route_fixes)} fixes, route {route_seconds:.0f} s, terminated {terminated:.0f} s, need {expected:.0f}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
