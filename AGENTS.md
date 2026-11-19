# AGENTS.md

Guide for coding agents (and humans) working on Spur, an iPhone app that records every drive
in full GPS and motion detail, shows which roads and directions you have already driven, and
plans routes over the ones you have not.

## Read first

- `SPEC.md` is the contract: features, storage, location engine, statistics, design language,
  tests and the definition of done. Code comments cite it as `SPEC <section>`.
- `docs/ANLEITUNG.md` is the user manual (German, as the UI).
- `docs/MOTION-FORMAT.md` documents the binary motion file `motion.bin`.

## Build and test

Requires Xcode 26 with an iOS 26 simulator and XcodeGen (`brew install xcodegen`).

```bash
scripts/install-font.sh            # optional: bundle a typeface you are licensed to embed
xcodegen generate                  # Spur.xcodeproj is generated, never committed
xcodebuild -project Spur.xcodeproj -scheme Spur \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build test
```

| Script | What it proves |
|---|---|
| `scripts/test-all.sh <udid>` | every unit test in Debug, plus the motion physics suite in an optimized build, and that both builds compute identical physics |
| `scripts/ui-flow.sh <udid>` | the real UI end to end: start, pause, drive, hold to stop, details, export, ZIP, Planen, gap fill, automatic pause, street search; writes `docs/screenshots/` |
| `scripts/sim-e2e.sh`, `scripts/motion-e2e.sh` | recording through the real engine in the simulator |

Always pass the simulator UDID: the scripts never fall back to "a booted simulator".

The offline road pack for Dallas (`Spur/Resources/OSM/roads.spurpack`) is not in the repository.
Without it the app loads road data live, two unit tests that measure on the pack are skipped
with a reason, and the Planen part of `ui-flow.sh` cannot run. `scripts/build-osm-pack.sh`
builds the pack and needs the parent project's tile extractor (`SPUR_PARENT`).

## Layout

```
Spur/App            app entry, environment, debug launch arguments (AppEnvironment)
Spur/Location       recording engine, motion recorder, road service (CoreLocation, CoreMotion)
Spur/Domain         pure logic: statistics, OSM matching, coverage, planner, exports, storage
Spur/UI             SwiftUI screens: Fahrt (live), Planen, Historie, Einstellungen
Shared              types shared with the widget extension (Live Activity)
SpurWidgets         Live Activity and Dynamic Island
SpurTests           unit tests (Swift Testing) with fixtures
SpurUITests         UI tests (XCTest) driven by scripts/ui-flow.sh
scripts             build, verification and screenshot scripts
```

## Rules that keep the app correct

- **Raw GPS fixes are never filtered, thinned or rewritten on disk.** Statistics filter in memory;
  derived files (coverage, gap fills) live next to the raw files, never inside them.
- **Never weaken, skip or delete a test to make it pass.** Change a test only when the requirement
  changed, and say why in the commit.
- **Swift 6, default actor isolation `MainActor`.** Every type is main-actor isolated unless marked
  `nonisolated`. A closure that a framework calls on a background queue (CoreMotion, CoreLocation
  delegates on their own queue, `URLSession` callbacks) must come from a `nonisolated` context, or
  Swift stops the app at runtime with an isolation check. Domain logic is `nonisolated` and pure.
- **Apple frameworks only.** No Swift packages, no SDKs, no analytics. Everything stays on the
  phone except map tiles, Apple's geocoder and the OpenStreetMap road data (Overpass).
- **UI copy is German, code and docs are English.** No em dash or en dash anywhere.
- **Debug switches** (`-SpurSeedDemo YES`, `-SpurSynthMotion YES`, `-SpurSynthPlace offRoad`, ...)
  live in `Spur/App/AppEnvironment.swift` and compile to constants in Release.

## Data and attribution

Road data comes from OpenStreetMap (ODbL), shown in the app as "Straßendaten © OpenStreetMap-
Mitwirkende (ODbL)". The optional offline road pack (`Spur/Resources/OSM/*.spurpack`) is
gitignored; without it Spur loads road data live from public Overpass servers. Test fixtures
under `SpurTests/Fixtures` are synthetic drives on OSM extracts.

## License

All rights reserved. See `LICENSE`: the source is visible, not licensed for use.
