# Spur: Product and Build Specification

Spur is a small iOS app for people who map road coverage by driving. It is the phone-only companion of a larger web app (the "parent", not public), whose import formats, OSM tiling and scenario definitions it follows.

It records exactly where the driver went with high-precision GPS, also while the app is in the background or the phone is locked, draws the driven trail with a direction arrow behind the current position, keeps a local history of trips with rich metadata, and exports everything.

Everything stays on the phone. No server, no account, no analytics, no third-party SDK.

---

## 0. Operating contract (for the build agent)

- Spur was built by coding agents against this specification, one numbered phase at a time (section 13). Decide without waiting for a human where the specification allows it, and record each decision with its reason (the maintainers keep a decision log).
- If a step truly needs a human (Apple ID login, a device unlock, a paid account), say so with the exact command or click path and continue with everything else that does not depend on it.
- The parent web app is a read-only reference where it is available. Never write there.
- No em dash and no en dash anywhere: UI copy, docs, comments, commits.
- No brand name anywhere: not in the app name, bundle id, UI copy, comments, file names you create, or commit messages. The look follows a calm, dark, precise in-car design language (section 8), but the product shows no logo or brand marks.
- UI work follows the design language in section 8: restraint, purposeful motion, accessible contrast.
- Never weaken, skip or delete a test to make it pass.
- No third-party dependencies (no SPM packages). Apple frameworks only: SwiftUI, MapKit, CoreLocation, Charts, Foundation, UIKit where needed; since 1.2 also CoreMotion, ActivityKit and WidgetKit (SPEC 16).

---

## 1. Users and context

- Drivers who record road coverage in their own cars (Dallas, Texas, and anywhere else).
- The phone sits in a mount. **The passenger operates the app, the driver never does.** After "Start" the recording must run without any interaction until "Stop".
- They want to see at a glance where they have already driven, how far, on which kind of road, and keep a precise record for later evaluation.

---

## 2. Features

### P0 (must ship)
1. **Recording** of high-precision GPS fixes at the maximum rate the device delivers, in foreground, background and with the screen locked (section 4).
2. **Live map** (section 7.1): the current trip as a trail line behind the position, a direction arrow at the current position oriented to the GPS course, direction chevrons along the recent trail, and all previously driven trips as a faint "bereits gefahren" layer.
3. **Live HUD**: speed, trip distance, trip duration, estimated road type now, GPS accuracy, recording state.
4. **Trip history** (section 7.2) stored locally, with totals.
5. **Trip detail** (section 7.3) with the full metadata of section 5 and the map of the trip.
6. **Export** (section 9): per trip GPX, CSV, GeoJSON, JSON; and "Alle Fahrten exportieren" as one ZIP.
7. **Crash and kill safety**: every fix is on disk within seconds; an open trip survives app termination and resumes on next launch.

### P1 (should ship)
8. **Ereignis markieren** during a trip: one tap drops a timestamped, located marker with a tag (Baustelle, Interessantes Szenario, Gefahrenstelle, Sperrung, Fahrbahnmarkierung schlecht, Schild verdeckt, Sonstiges). Markers appear on maps and in exports.
9. Trip note and rename after the trip.
10. Units toggle: km and km/h (default) or mi and mph.
11. Exports also land in `Documents/Exports`, visible in the Files app (`UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`).

### P2 (only if everything above is verified)
12. Landscape layout of the live screen for horizontal mounts.
13. Live Activity / Dynamic Island showing recording time and distance.

---

## 3. Storage (local, file based, append only)

- Root: `Application Support/Spur/Trips/<tripId>/` with explicit file protection `completeUntilFirstUserAuthentication` (writes must work while the phone is locked).
  - `trip.json`: metadata and cached statistics (section 5), schema versioned (`"schema": 1`).
  - `fixes.<ext>`: the raw fixes, append only, one record per fix, a version header line, written as each fix arrives. Synchronize to disk at least every 10 s and on every app state change. A truncated last record (crash mid-write) must be tolerated on read and covered by a test.
  - `events.json`: markers (P1).
  - `thumb.png`: cached map snapshot for the history list.
- **Never downsample or filter raw data on disk.** Every fix the system delivers is stored. Filtering happens only in statistics and display.
- Per fix, store every field `CLLocation` offers: timestamp (ms precision), latitude, longitude (full Double precision), horizontalAccuracy, altitude, ellipsoidalAltitude, verticalAccuracy, speed, speedAccuracy, course, courseAccuracy, `sourceInformation.isSimulatedBySoftware`, `sourceInformation.isProducedByAccessory`. An invalid value (negative accuracy, speed or course where Core Location marks it invalid) is stored as null, never as a fake number.
- A trip index is rebuilt from the folders at launch (a few hundred trips must load in well under a second; cache summary data in `trip.json`).
- Persist "recording in progress" (trip id) in `UserDefaults` so a relaunch can resume.

---

## 4. Location engine (the core, get this exactly right)

Verify every API against the iOS 26 SDK headers in Xcode, not from memory.

- `CLLocationManager`: `desiredAccuracy = kCLLocationAccuracyBestForNavigation`, `distanceFilter = kCLDistanceFilterNone`, `activityType = .automotiveNavigation`, `allowsBackgroundLocationUpdates = true`, `pausesLocationUpdatesAutomatically = false`, `showsBackgroundLocationIndicator = true`. Amended for 16.4: while the trip's Live Activity is live and the authorization is Always, `showsBackgroundLocationIndicator = false` (the activity shows that Spur records; the blue pill would push it to the island's smallest form); in every other case `true`.
- Hold a `CLBackgroundActivitySession` for the whole recording (started while in foreground), released on stop.
- Info.plist: `UIBackgroundModes = [location]`, `NSLocationWhenInUseUsageDescription`, `NSLocationAlwaysAndWhenInUseUsageDescription`, `NSLocationTemporaryUsageDescriptionDictionary` with a purpose key for full accuracy. German texts.
- Authorization: ask "Beim Verwenden" on the first Start. Offer the upgrade to "Immer" in a calm card (Settings and first-trip hint) and explain why: it lets iOS relaunch Spur if the system ends it during a trip. While recording, also run `startMonitoringSignificantLocationChanges()` as a relaunch trigger; stop it on Stop.
- Reduced accuracy (user turned "Genaue Position" off): show a persistent warning banner and request temporary full accuracy with the purpose key.
- Denied or restricted: clear empty state with a button that opens the app's iOS settings.
- **Gaps**: when two consecutive fixes are more than 5 s apart, record a gap (start, end, reason if known: `background`, `relaunch`, `signal`). Statistics and GPX segments split at gaps.
- **Resume**: on launch, if a trip is marked recording, restart the engine immediately (also when launched in the background by a location event), record a `relaunch` gap, and continue the same trip.
- Keep the screen awake while recording and the app is in the foreground (setting, default on), via `isIdleTimerDisabled`.
- The location callback does minimal work: append to the fix file, update the in-memory live state, throttle UI updates. No heavy computation per fix.

---

## 5. Metadata and statistics (pure functions, unit tested)

Write all of these as pure Swift functions over an array of fixes (no I/O, no UI), in their own files, each with tests. Definitions follow the parent spec section 7 where they overlap. Shown in the detail screen with a short info text that states the exact definition.

- **Usable fix**: horizontalAccuracy known and at most 30 m (constant, adjustable in Settings). Unusable fixes are stored but excluded from distance and road type.
- **Distance**: haversine sum between consecutive usable fixes, skipping across gaps. When valid speed is below 1 m/s, position does not advance (stationary jitter adds nothing).
- **Time**: total duration (start to end), moving time (speed at least 1 m/s), stopped time.
- **Speed**: average over total duration, moving average, max (only fixes with valid speed and speedAccuracy at most 2 m/s when known), p85, speed histogram in 10 km/h bins.
- **Stops**: speed below 1.0 m/s for at least 3 s. Count, total stopped time, longest stop, start-stop events (stop followed by moving) also per km.
- **Road type (geschätzt)**: classify continuous driving into `Stadt`, `Land`, `Autobahn` from the speed profile, offline, no network:
  - rolling window of 60 s of usable fixes, median speed of moving fixes;
  - `Autobahn`: median at least 85 km/h; `Land`: 50 to 85 km/h; `Stadt`: below 50 km/h, or more than 2 stops per km in the window;
  - hysteresis: a new class must hold for 30 s before it replaces the old one;
  - output: distance and time per class, and per-fix class for coloring.
  - Always labelled "geschätzt" in the UI with an info text explaining the rule. Put the thresholds in one constants file and in the decision log.
- **Elevation**: min, max, gain and loss with a 3 m hysteresis (do not sum noise).
- **Dynamics (ca.)**: hard acceleration and hard braking events above 3 m/s² derived from consecutive valid speeds with dt at most 2 s; labelled "ca.".
- **Day and night**: share of driving time with the sun above -0.833° altitude, computed locally (NOAA solar position algorithm), no API.
- **GPS quality**: fix count, mean fix rate (Hz), median and p95 horizontalAccuracy, percent of fixes at most 5 m, percent above 30 m, gap count and total gap duration, count of simulated fixes, count of accessory fixes.
- **Places and streets**: reverse geocode with MapKit (`MKReverseGeocodingRequest` on iOS 26, check the SDK) at trip start, at trip end, and while moving at most once per 60 s and at least 1 km apart. Store locality and street name with the fix time. Derive: start place, end place, list of localities in order, list of streets with approximate distance per street. Setting "Orte und Straßennamen ermitteln" (default on); when off, nothing leaves the phone except map tiles. Geocoding failures are silent and never block recording.
- **Context metadata** per trip: driver name and vehicle nickname (from Settings, both free text), device model identifier, iOS version, app version and build, battery level and Low Power Mode at start and end, time zone, start and end timestamps, authorization level used (`always`, `whenInUse`), accuracy authorization (`full`, `reduced`).

---

## 6. Units and language

- UI copy in German. Code, identifiers, comments and docs in English.
- Units: km and km/h by default, setting to switch to mi and mph. Internally always SI.
- Number formatting with the German locale for display; exports always use `.` as decimal separator and ISO 8601 UTC timestamps.

---

## 7. Screens

A tab bar with three tabs: **Fahrt**, **Historie**, **Einstellungen**. Dark appearance only.

### 7.1 Fahrt (live)
- Full screen MapKit `Map`, muted dark standard style, points of interest excluded, realistic elevation off for clarity.
- **Trail**: the current trip as a polyline in the accent blue with a soft wider underglow, drawn from a display-decimated copy (at most about 2000 vertices; raw data untouched).
- **Direction**: an arrow puck at the current position rotated to the GPS course (fallback: last bearing between fixes), plus chevrons along the last ~3 km of trail every ~250 m, rotated to the local bearing, at most 15.
- **Bereits gefahren**: all previous trips, decimated, as thin white lines at low opacity. A map button toggles this layer.
- **Accuracy halo**: a faint circle with radius horizontalAccuracy around the puck.
- Camera: follows the position, course-up by default with a toggle to north-up; a recenter button appears when the user pans away.
- **HUD** (glass surfaces over the map, glanceable from 1 m away):
  - top: recording pill (pulsing red dot, elapsed time) or "Bereit"; GPS chip (`± 4 m`, green at most 5 m, amber up to 15 m, red above, grey when no fix); road type now (`Autobahn · geschätzt`).
  - bottom card: current speed very large with unit, trip distance, duration, moving average.
  - primary control: a large blue **Start** button. **Stop** is a press-and-hold (about 1.2 s) with a progress ring, so it can never trigger by accident and needs no modal. After stop, a short summary sheet with "Fahrt ansehen".
  - **Ereignis** button (P1) during recording: opens a compact tag picker (one tap per tag), confirms with haptic and a brief toast.
  - small footer line: "Bedienung nur durch Beifahrer".
- Banners for: location denied, reduced accuracy, recording resumed after a gap, low battery (below 15%).
- No modal or alert while recording except permission system prompts.

### 7.2 Historie
- Header with totals: total distance, trips, driving time, share per road type.
- Trips grouped by day, newest first. Each row: map thumbnail (cached `MKMapSnapshotter` image), title (start place to end place, or date and time when unknown), start time, distance, duration, a thin stacked bar of the road-type shares.
- Swipe to delete with a confirmation. A running trip is shown at the top as "Läuft".
- Empty state that explains how to start.
- Toolbar: "Alle exportieren" (ZIP).

### 7.3 Fahrt-Details
- Map of the whole trip, track colored by speed or by road type (segmented toggle), start and end markers, event markers, gap markers.
- Sections with large readable numbers: Übersicht, Streckenart (geschätzt), Geschwindigkeit (line chart over time and histogram, Swift Charts), Höhe (area chart), Stopps, Fahrdynamik (ca.), Tag und Nacht, GPS-Qualität, Orte und Straßen, Fahrer und Gerät, Ereignisse, Notiz.
- Every metric has an info affordance with its exact definition (section 5).
- Toolbar: Teilen (GPX, CSV, GeoJSON, JSON), Umbenennen, Notiz, Löschen.

### 7.4 Einstellungen
- Fahrer (name), Fahrzeug (nickname), Einheiten, Orte und Straßennamen ermitteln, Display während der Fahrt anlassen, Genauigkeitsfilter (m), location permission status with an explanation and a button to iOS settings, storage used, "Alle Fahrten exportieren", "Alle Fahrten löschen" (with typed confirmation), version.

---

## 8. Design language

Look and feel of a calm, dark, precise in-car and app UI: engineered, never decorative.

- **Typeface**: an optional single-weight typeface (any font file placed in `Spur/Resources/Fonts/`, registered at launch), else the system font. Only one weight is assumed: build hierarchy from size, case, letter spacing and opacity, never from synthesized bold. Small labels in uppercase with generous tracking. Large numerals for speed and distance. Provide one `Typography` helper that falls back to the system font if the custom font fails to load, and a unit test that asserts a bundled font file registers and is used, and that without one every style uses the system font.
- **Color**: near-black background (`#0A0C0F` range), elevated surfaces as translucent glass (iOS 26 `glassEffect` / materials), one accent blue (`#1C69D4`) for the trail, primary buttons and selection, a lighter blue for highlights, white text at 92% and 60% opacity, semantic green, amber and red only for status. Road types: Stadt, Land, Autobahn as three distinct calm tones that read on dark and are distinguishable for color-blind users.
- **Shape**: generous corner radii on cards, hairline separators, 8 pt spacing grid, touch targets at least 48 pt, primary control at least 72 pt.
- **Motion**: purposeful and quick. Springs for state changes, `contentTransition(.numericText())` for changing numbers, the hold-to-stop ring, a soft pulse on the recording dot. Respect Reduce Motion everywhere.
- **Icon**: an app icon generated by a script in `scripts/` (abstract trail line with an arrowhead on a deep blue gradient). No logo.
- Readability in sunlight: high contrast, no thin gray-on-gray text.

---

## 9. Export formats

All exports use `.` decimals and ISO 8601 UTC timestamps with milliseconds, and are produced by pure, tested functions.

- **CSV** (compatible with the parent import, its `src/lib/capture/csv.ts`): header `timestamp,lat,lon,accuracy,speed,heading,altitude` followed by `altitudeAccuracy,ellipsoidalAltitude,speedAccuracy,headingAccuracy,simulated,accessory,segment,roadType`. Empty field for null.
- **GPX 1.1**: one `trk`, one `trkseg` per gap-separated segment, `trkpt` with `ele` and `time`; speed, course and accuracies in a namespaced `extensions` block; markers as `wpt`. Must be well-formed XML with escaped text (test with `XMLParser`).
- **GeoJSON**: a FeatureCollection with one LineString per segment (properties: trip metadata and statistics) and one Point per marker. Coordinates in `[lon, lat, ele]` order.
- **JSON**: the full `trip.json` plus statistics and events.
- **Alle Fahrten**: a ZIP (via `NSFileCoordinator` with `.forUploading` on a folder, no dependency) containing each trip's four files and a `trips.csv` summary with one row per trip.
- Sharing via `ShareLink` / the share sheet; a copy also goes to `Documents/Exports`.

---

## 10. Project setup

- XcodeGen `project.yml`; the generated `.xcodeproj` is gitignored. `Config/Base.xcconfig` holds the shared settings; team and bundle prefix in the gitignored `Config/Local.xcconfig` (already present), `Config/Base.xcconfig` with empty defaults and `#include? "Local.xcconfig"`.
- App name `Spur`, bundle id `$(SPUR_BUNDLE_PREFIX).spur`, iOS deployment target 26.0, iPhone only, portrait (landscape is P2).
- Swift 6 language mode with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and approachable concurrency. If that costs more than 30 minutes of compiler fighting, use Swift 5 mode and record why in the decision log.
- Targets: `Spur` (app), `SpurTests` (unit tests, Swift Testing). UI tests are optional.
- Font files are gitignored (only embed a font you are licensed to). `scripts/install-font.sh <file>` copies one into `Spur/Resources/Fonts/`; the app and the extension register it at launch. Builds without a font file must still succeed and use the system font.
- Debug-only launch arguments (compiled out of Release):
  - `-SpurSeedDemo YES`: creates four synthetic demo trips (generated from waypoints in code, clearly synthetic, never real recorded data) for screenshots and UI review.
  - `-SpurAutoStart YES`: starts a recording right after launch (for simulator automation).
- `README.md` (English, short: what, build, run, test, privacy) and `docs/ANLEITUNG.md` (German, for colleagues: install, permissions, start and stop, what the map shows, what "geschätzt" means, export, known limits).

---

## 11. Tests

### 11.1 Unit (Swift Testing, `SpurTests`)
Cover: every function in section 5 with hand-computed fixtures (distance, moving time, stationary jitter adds no distance, stops, start-stop, road-type classification including hysteresis, elevation hysteresis, dynamics events, sun position against known values for a fixed place and date, GPS quality, p85), gap detection and segment splitting, display decimation (vertex budget, endpoints kept), fix file round trip including a truncated last record, trip store index rebuild, every exporter (CSV header and values, GPX parses with `XMLParser`, GeoJSON parses with `JSONSerialization` and has `[lon, lat]` order), unit conversion, the font load test.

### 11.2 Simulator end to end (`scripts/sim-e2e.sh`, prints PASS or FAIL per check)
1. `xcodegen generate`, build for an iOS 26 simulator, install, `xcrun simctl privacy <udid> grant location-always <bundle id>`.
2. Launch with `-SpurAutoStart YES`; drive a synthetic route with `xcrun simctl location <udid> start --speed=25 --interval=1 <waypoints>` (at least 40 waypoints, about 15 km).
3. After 20 s send Spur to the background (`xcrun simctl launch <udid> com.apple.Preferences`), wait 60 s, bring Spur back.
4. Then `xcrun simctl terminate` Spur mid-trip, wait 10 s, relaunch without autostart, wait 30 s.
5. Read the fix file from `xcrun simctl get_app_container <udid> <bundle id> data` and assert:
   - background window: no gap longer than 3 s while in background;
   - the same trip id continued after relaunch, a `relaunch` gap is recorded, fixes continue after it;
   - fix count is at least 90% of the seconds the route ran, minus the terminated window.
6. Capture screenshots into `docs/screenshots/`: live recording, history (with seed data), trip detail top and lower sections, settings, permission-denied state.

### 11.3 Parent compatibility
Export one demo trip as CSV and GPX and parse both with the parent's parsers in `src/lib/capture/` (path from `SPUR_PARENT`) from a scratch script outside both repos (do not modify the parent). Report the parsed fix counts.

---

## 12. Definition of done

All lines true, each backed by command output in the session:
1. `xcodegen generate` and `xcodebuild build` for the simulator exit 0 with no errors.
2. `xcodebuild test` shows 0 failed tests, with the test count stated.
3. `scripts/sim-e2e.sh` prints PASS for every check.
4. Screenshots exist for every screen in 11.2 step 6 and were reviewed against section 8.
5. A device build (`generic/platform=iOS`, automatic signing with the team in `Config/Local.xcconfig`, `-allowProvisioningUpdates`) succeeds, or a precise `BLOCKED:` line explains what is missing.
6. Parent compatibility check (11.3) parses the exports.
7. The decision log, `README.md` and `docs/ANLEITUNG.md` exist; the working tree is committed.
8. `git grep -nP "\x{2014}|\x{2013}"` (em and en dash) over tracked files finds nothing.

---

## 13. Phases (commit after each)

1. Scaffold: XcodeGen project, configs, font script, empty app with tab bar that builds and launches in the simulator.
2. Domain: fix model, fix file store, trip store, all statistics and exporters as pure code, with the full unit test suite green.
3. Location engine: recording, background, gaps, resume, permissions, geocoding sampler.
4. UI: design system, live screen, history, detail, settings (invoke the design skills first).
5. Export and share, ZIP, Files app.
6. Verification: `sim-e2e.sh`, screenshots, parent compatibility, device build. Fix what fails.
7. Polish pass against section 8 using the screenshots, docs and final commit, with evidence for section 12 line by line.

---

## 14. Version 1.1: position accuracy and road data

This version adds two things: the recorded position is as precise as the phone allows, and the parent's road knowledge comes back: traffic signals, skewed intersections, streets with many signals, stop signs and streets with many stop signs, both on the map and as data per trip.

Sections 0 to 13 still apply. This section overrides the earlier decision that nothing but map tiles and Apple geocoding leaves the phone: road data now comes from OpenStreetMap. Record the reversal in the decision log.

### 14.0 Hard constraints for this version
- Installed copies already hold recorded trips. **Never break existing data:** the fix file stays at format version 1; every `trip.json` change is additive (new optional fields); a test loads a trip.json written by the current version (commit `8cf7717`) and all its old fields survive a save.
- Recording never waits on the network or on road data. All road analysis runs off the main actor, bounded, and can be re-run later from the raw fixes.
- Only tile bounding boxes ever go to a server, never fixes or the track.
- Road counts are labelled "laut OpenStreetMap". Stop-sign tagging in OSM is incomplete, so stop counts are a lower bound and the info text says so.
- OSM attribution "Straßendaten © OpenStreetMap-Mitwirkende (ODbL)" is visible in Settings and on every screen that shows road data.

### 14.1 Position accuracy
1. Verify, with a unit test against the injected manager, that the real recording configuration is unchanged: `kCLLocationAccuracyBestForNavigation`, `kCLDistanceFilterNone`, `.automotiveNavigation`, `pausesLocationUpdatesAutomatically = false`, background updates on, temporary full accuracy requested when reduced. Do not change the activity type.
2. **Warm-up:** while the Fahrt tab is visible, the app is in the foreground and not recording, run foreground-only location updates (no background session, no significant-change monitoring) so the GPS chip shows the live accuracy before Start ("± 4 m"), coloured as in 7.1. Stop them when the app leaves the foreground or the tab changes. These fixes are not stored.
3. **Precision banner** while recording: when the median horizontal accuracy of the last 30 s of fixes is above 15 m for 30 s, show a calm banner "Ungenaue Position (± 18 m): freie Sicht zum Himmel?" that clears itself when it recovers. Never a modal.
4. Trip detail, GPS-Qualität: also show the share of fixes at most 5 m and at most 10 m, and "Externer GNSS-Empfänger" with its share when accessory fixes exist (an MFi receiver feeds Core Location directly; nothing else to integrate).

### 14.2 Road data source (tiles)
- Tiles are slippy z13 tiles, the same tiling and the same Overpass query as the parent (`src/lib/osm/overpass.ts`, `buildRoadsQuery`: kept road classes, feature nodes, and the neighbouring ways that share a node, so junction angles at tile edges are complete). Read-only reference.
- **Source chain**, first hit wins: (1) on-device cache, (2) the bundled offline pack, (3) live Overpass.
- **Offline pack for the Dallas area:** `scripts/build-osm-pack.sh` downloads `https://download.bbbike.org/osm/bbbike/Dallas/Dallas.osm.pbf` (public OSM extract, about 47 MB, into a gitignored folder), runs the parent's `scripts/extract-osm-tiles.py` (by its absolute path with `uv run --with osmium`, output to stdout, nothing written into the parent repo), and writes one LZFSE-compressed tile per entry into a single pack file bundled with the app (gitignored like the font; the app works without it). The pack keeps the Overpass JSON shape so live tiles and pack tiles go through one parser. Record pack date, area and size in the pack header and show them in Settings.
- **Live Overpass** only for tiles the pack does not cover, behind the setting "Straßendaten aus dem Internet laden" (default on; explanation: only the square areas of about 4 km around the route are sent, never the route). Endpoints with failover: `overpass-api.de`, `overpass.private.coffee`, `overpass.kumi.systems`. One request at a time, at most one per 2 s, exponential backoff on 429, 502, 503, 504 and timeouts, timeout 60 s, `User-Agent: Spur/1.1 (iOS)` with no personal data. Public Overpass was failing during planning (502 and timeouts on all three), so failures must be silent, retried later and never block anything.
- While recording, request the tile under the position and its 8 neighbours. "Gebiet vorladen" in Settings loads all tiles within 15 km of the current position (progress, cancel, Wi-Fi hint).
- Cache: `Application Support/Spur/OSM/`, parsed compact form, TTL 30 days, size cap 300 MB with least-recently-used eviction, "Straßendaten-Cache leeren" in Settings.

### 14.3 Road features (pure, tested, parity with the parent)
- Feature nodes: `highway=traffic_signals|stop|give_way|crossing|mini_roundabout|motorway_junction` and `railway=level_crossing`, same precedence as the parent's `taggedFeatureType`.
- **Skewed junction**: parent rule (DECISIONS 9 of the parent): at least three approaches; skewed when any approach pair meets below 70 degrees, or above 110 and below 150 degrees; approach bearing to the first arm node at least 15 m away. Port `src/lib/osm/features.ts` exactly.
- **Signal sites**: signal nodes that belong to one intersection (divided roads carry two to four) are merged into one site: signal nodes within 30 m of each other that are connected through kept ways within that distance. Every count is per site.
- **Stop signs**: `highway=stop` applies to the travel direction given by `direction=forward|backward` relative to the way's node order (also `stop:direction` / `traffic_signals:direction` where present); untagged means it applies. `stop=all` marks an all-way stop.
- **Streets with many**: per street (OSM `name`, else `ref`, else way id) with at least 300 m driven in the trip: signal sites per km and stop signs per km. "Viele Ampeln" when signal sites per km is above 3 (parent `DEFAULT_SIGNALS_PER_KM`); "viele Stoppschilder" with the same threshold. Constants in one file.
- **Road category** from OSM tags with the parent's category rules (`src/lib/osm/categories.ts`: Interstate, Freeway, Tollway, Highway, Expressway, Ramp, Frontage road, Arterial, Local), plus `maxspeed` where tagged.

### 14.4 Matching (decide by measurement)
- Start with a light matcher, pure and tested: candidates are way segments within `clamp(2 x horizontalAccuracy, 12, 30)` m; when speed is at least 3 m/s and course is valid, a candidate whose bearing differs from the course by more than 40 degrees is rejected (oneway and roundabout ways only in their legal direction); score is perpendicular distance plus a penalty for leaving the current way unless the new way shares a node with it; switching to an unconnected way needs 3 consecutive fixes that prefer it; fixes above 30 m accuracy or below 1 m/s keep the current match.
- **Containment rule:** a feature counts only when its node lies on the matched path: the matched positions on a way bracket the node's position along that way, or the match changes ways at that shared node. Proximity alone never counts (a frontage-road signal beside or under a freeway must not count while driving the freeway).
- **Oracle from the parent** (read-only): a scratch bun script, kept in `tools/` of this repo and run with the parent as the working directory if its path aliases need it, exports for the nine parent fixtures (`test/fixtures/osm/*.json`, `test/matching/scenarios.ts` cases 1 to 9): the synthetic drives (fixes with time, position, accuracy, speed, heading), the ground-truth route node sequences, the feature nodes passed in travel order derived from them, and the parent's skew flag for every junction node. Commit the exported JSON as Swift test fixtures (OSM data, ODbL).
- **Acceptance**, printed as a table per case by the test: skew flags equal the parent's for 100% of junction nodes in all nine fixtures; feature-pass precision at least 95% and recall at least 90% on cases 1, 2, 4, 5, 6, 8 and 9; cases 3 and 7 must reach precision at least 90% and document the rest in the decision log. Case 6 (downtown grid, 60 s red light): exactly 1 stop, classified "an Ampel".
- If the light matcher misses the acceptance, port the parent's HMM matcher (`src/lib/matcher/*`) to Swift and measure again. Never lower a threshold.

### 14.5 Trip analysis and statistics (additive)
- Run at stop (off main) with whatever tiles are available, and again via "Neu auswerten" in the detail screen and automatically when missing tiles arrive later. Store the result as an optional `roads` block in `trip.json` with the analysis version, the tile sources used and the road-data coverage (share of distance matched).
- Per trip: signal sites passed, stop signs passed (of which all-way), give way, roundabouts, level crossings, motorway junctions, skewed junctions passed; stops classified at a signal (within 30 m of a signal node of the matched path), at a stop sign, or other (parent SPEC 7); streets with many signals and with many stop signs (list with name, driven km, count, per km); distance and time per OSM road category; share of distance with a known speed limit and the share driven more than 5 mph (8 km/h) above it.
- The speed-based road type (Stadt, Land, Autobahn, "geschätzt") stays as the fallback where nothing is matched; the UI says which one it shows.
- History totals gain total signal sites and stop signs passed.

### 14.6 UI
- **Live map:** a POI layer (map button toggle, default on) with small, calm symbols in the design language for signal sites, stop signs (all-way marked) and skewed junctions in the visible area, capped at about 150 symbols with the nearest kept; streets with many signals subtly highlighted. The HUD secondary line gains live counters ("7 Ampeln · 2 Stopp · 1 schräg") without growing the card.
- **Trip detail:** new section "Kreuzungen und Verkehrszeichen (laut OpenStreetMap)" with the counts, stop classification, the two "Straßen mit vielen ..." lists and the road categories; the trip map can show the passed features; every number has an info text with its exact rule; the data coverage line ("Straßendaten für 97 % der Strecke").
- **Settings:** the internet toggle, "Gebiet vorladen", offline pack info (area, date), cache size and clear, attribution.
- Invoke the design skills before the UI work.

### 14.7 Export
- JSON: the `roads` block and a list of passed features (node id, type, site id, time, position, way id, street).
- GeoJSON: one Point per passed feature with its type.
- CSV: extra trailing columns `wayId,street,osmCategory` (the parent import ignores unknown columns; re-run `scripts/parent-compat.sh`).
- `trips.csv`: the new per-trip counts.

### 14.8 Tests and verification
- Unit: parser on Overpass JSON, pack round trip, cache eviction, skew parity, signal sites, stop direction, streets-with-many, categories, matcher acceptance table (14.4), old trip.json compatibility (14.0), configuration test (14.1).
- Simulator: a DEBUG-only launch argument loads a fixture as the road pack; replay case 6 (downtown grid) through the real engine with `simctl location start` and the UI flow (Start, hold to stop); assert the stored trip's signal-site count and stop classification against the oracle. Re-run `sim-e2e.sh`, `ui-flow.sh`, `parent-compat.sh`, all unit tests.
- Screenshots: live map with the POI layer, the new detail section, Settings road-data part; review them against section 8.
- Device: when the connected iPhone is unlocked, `scripts/install-device.sh` upgrades the app in place (data kept). If it is locked, the device step is reported as BLOCKED and the other steps continue.

### 14.9 Phases (commit after each)
- R1 accuracy (14.1). R2 tiles: pack script, parser, cache, Overpass client (14.2). R3 features and matcher with the oracle and the acceptance table (14.3, 14.4). R4 analysis and statistics (14.5). R5 UI (14.6). R6 export, verification, screenshots, docs (`docs/ANLEITUNG.md` gains a road-data part, `README.md`, the decision log), install, and the evidence for every line of 14.8 and the acceptance table.

## 15. Driven directions on the map

Requirement: the arrows of the driven directions are always shown along the driven roads, not only briefly behind the current position. A road is coloured by whether it was driven in one direction or in both, and its arrows point in one direction or in both accordingly.

### 15.1 What counts as driven
- Unit: one OSM edge, the piece of a way between two consecutive nodes, per travel direction (forward means along the way's node order). Edges, not segments: a segment's end depends on which junctions the loaded tiles contain, so its id can differ between chunks and trips; an edge never does.
- An edge direction is driven in a trip when the trip's matched path (the stop analysis, SPEC 14.4 HMM) covers at least 70 % of the edge's length in that direction, intervals of one trip united (the parent's `COVERAGE_MIN_FRACTION`, applied per edge).
- Across trips the directions are united. State of an edge: **both** when it was driven in both directions, else **one** (in the driven direction). A one-way way can only be driven one way: it stays **one** and its arrow shows the legal direction. Amendment: a divided road driven out and back is the same road driven both ways, even with a divider, so it is drawn green with arrows in both directions. A driven edge of a one-way way is **paired** when, at most 60 m across from its middle (the foot of the perpendicular inside the other edge), a driven edge of another one-way way with the same highway class and name (else ref) runs the other way (bearings at least 150 degrees apart), across all trips. Paired carriageways are drawn green like **both**, each with single arrows in its own legal direction, so together they point both ways. Unnamed ways never pair; the class keeps a frontage road that carries the freeway's name from pairing with the freeway. Pairing is drawing only: the stored directions do not change.
- Stored per trip in `coverage.json` (edges grouped into runs along a way, version 2 with each way's class plus name and its one-way flag; a file of another version sends its trip back to the analysis), written by every analysis, also when empty, so a trip is never re-analyzed only for this. Trips analyzed before 15 get it through the existing analysis queue.

### 15.2 Map
- Live map, under the current trail: every driven edge of the earlier trips (with the "bereits gefahren" layer on), amber `#FFB224` for one direction, green for both, 4 pt, on a thin dark casing. Runs of edges with the same state and direction are drawn as one line; only lines near the view, at most a fixed budget.
- Arrows on those lines: one direction, one chevron in the driven direction; both directions, two opposite chevrons side by side, each on the right-hand side of its direction. Spaced in screen points (about 60 pt), thinned when zoomed out, never hidden. White with a dark casing, the look of the trail chevrons.
- The current trip: chevrons along the whole trail, not only the last 3 km and 15 (spaced like the arrows above, only near the view). Its coverage appears after the stop analysis; live colouring of the running trip is not part of 15 (the light matcher failed acceptance on frontage roads, case 1 precision 88 %).
- Turning the layer on says what the colours mean ("Gelb: eine Richtung, Grün: beide Richtungen").
- Performance: the new overlays live in state rebuilt only when coverage, zoom step or view cell changes, never on every fix; the live buttons test and the main-thread profile are re-run.

### 15.3 Done when
Unit tests for the edge rule (70 %, union of intervals, direction mapping, both/one, one-way), the merge across trips, the chaining and the arrow placement; the case 8 oracle drive (out north, around the block, back south) gives both-direction edges, and its coverage in small chunks equals one chunk; a screenshot shows a one-direction street and a both-directions street with their arrows; all existing checks re-run; installed on the phone.

## 16. Version 1.2: motion sensor, speed limit, Live Activity

This version adds three features from the idea list: **3 motion sensor**, **7 speed limit in the HUD**, **10 Live Activity**, after SPEC 15.

Sections 0 to 14 still apply, especially 14.0: never break existing data. `fixes` stays
format v1. Every `trip.json` change is additive. Old trips without the new data must open and
export exactly as before.

### 16.1 Order and phases (commit after each)
- **B0 signing spike (30 min max):** add an empty widget extension target `SpurWidgets`
  (bundle id `$(SPUR_BUNDLE_PREFIX).spur.widgets`, XcodeGen) and prove `scripts/install-device.sh`
  signs and installs app plus extension on a paired iPhone. If the free team cannot sign the
  extension, report `BLOCKED: Live Activity signing | <exact error>` and skip 10 entirely. Remove the target again in
  that case.
- **B1 speed limit (7)**, same files as section 15, so right after it.
- **B2 to B4 motion sensor (3):** recording, analysis, UI and export.
- **B5 Live Activity (10).**
- **B6 verification, screenshots, docs, install,** with evidence covering section 15 and this
  section. Bump to 1.2.0 (4) once, at the end.
- Build no other "feature ideas" in this version; they stay on the idea list.

---

### 16.2 Speed limit in the HUD (idea 7)

**Source.** OSM `maxspeed` of the way the car is on, from the live road layer (`LiveRoads`, light
matcher). `RoadRules.maxspeedMph` already parses tags. Show only tagged values: no defaults, no
guessing.

**Show only on a stable match.** The light matcher failed acceptance on frontage roads versus
freeways (case 1 precision 88.3 %). A wrong limit is worse than none, so all of these must hold:
- the match has stayed on the same way for at least 3 consecutive fixes and at least 30 m;
- horizontal accuracy is at most 15 m;
- speed is at least 2 m/s, or the car is stopped on the way it was stably matched to;
- no other candidate segment within the candidate radius, with a compatible bearing, carries a
  *different* limit with a close score. Parallel frontage and freeway lanes therefore hide the
  sign instead of flickering.

Otherwise the sign is hidden: no empty sign and no "?". Fade it in and out at 200 ms (design skills).

**Display unit.** A limit is a sign value, so show it **in the tag's own unit**. A `mph` tag
gives a US-style rectangular white sign with the number. A unitless or `km/h` tag gives a round
sign with a red ring. The speed readout stays in the user's unit setting. Record this in
the decision log. The sign carries no words (no "SPEED LIMIT"), so there is no English UI copy.

**Over the limit.** Use the fix speed, only when `speedAccuracy` is at most 2 m/s. The state
goes red when speed > limit + 5 mph (8 km/h) for at least 2 s. It clears when speed ≤ limit + 3 mph
(5 km/h) for at least 2 s (hysteresis). Red means the speed number takes the danger colour and the
sign gets a thin danger outline. No sound and no haptic: the driver must not be distracted.

**Layout.** The sign sits beside the speed readout inside the existing bottom card. The card must
not grow (measure the frame before and after in a UI test or with a snapshot assert). Accessibility
label: "Tempolimit 45 mph laut OpenStreetMap" plus ", 8 mph darüber" when red.

**Setting.** "Tempolimit anzeigen" (default on), in the road-data part of Settings. That part's
text says the source is OpenStreetMap and that it can be missing or wrong.

**Tests.**
- Pure selection logic on `SpurTests/Fixtures/osm/i35e-stemmons-frontage.json` (freeway 60 mph,
  frontage 40 mph): a drive on the frontage must never show 60. Where both are candidates, the
  sign is hidden.
- Downtown grid: 30 mph shown after the stability rule.
- Hysteresis, `speedAccuracy` gating and the 2 s rule.
- `replay-case6.sh`: assert the sign appears with the fixture's value on the downtown replay.
  Find its accessibility element, or use a DEBUG-only state dump if the HUD is not reachable.

---

### 16.3 Motion sensor, accelerometer and gyroscope at 50 to 100 Hz (idea 3)

Goal: exact braking and acceleration values, cornering and road roughness instead of the coarse
GPS estimate (`DynamicsStats`, Δv/Δt between 1 Hz fixes, which stays for old trips and as the
fallback).

#### 16.3.1 Recording
- `CMMotionManager` (one instance in the app) `startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue)`
  on a dedicated `OperationQueue`, **never on the main actor**. Do not use the magnetometer frames:
  magnetic phone mounts corrupt them.
- Rate: setting "Abtastrate" 100 Hz (default) or 50 Hz. Setting "Bewegungssensor aufzeichnen"
  (default on). Runs only while a trip records, never during warm-up.
- Per sample, store raw: sensor timestamp mapped to wall-clock time (see time base),
  `userAcceleration` xyz (g), `gravity` xyz (g), `rotationRate` xyz (rad/s), `attitude.quaternion`
  xyzw. Nothing is filtered or downsampled on disk (same rule as fixes).
- **Time base:** `CMLogItem.timestamp` is seconds since boot, not wall clock. Map it with
  `offset = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime`, re-taken per
  write batch, and store wall-clock unix seconds (Float64) per sample. Test the mapping with an
  injected clock.
- **File:** `motion.bin` next to `fixes.*`. Append only, little-endian, a fixed binary header (magic,
  format version 1, record size, nominal rate, reference frame) and then fixed-size records
  (Float64 time plus Float32 channels: about 60 bytes, about 21.6 MB per hour at 100 Hz). **Measure
  the real bytes per hour** in a test and print it. Write in batches (about every 1 s), sync at
  least every 10 s and on every app state change, with the same file protection as fixes. A
  truncated last record (crash mid-write) is ignored on read (test). Document the format in
  `docs/MOTION-FORMAT.md`; the ZIP export carries it too.
- **Lifecycle:** start with the trip; on resume after a kill, reopen and append. Detect gaps
  (sample interval > 0.5 s) in analysis, not on disk. Stop with the trip. Battery and thermal:
  log the thermal state at start and end into the trip context (additive).
- **Injection:** a `MotionSource` protocol like the location manager's. Real: CoreMotion. Tests: a
  scripted source. The simulator has no motion hardware (`isDeviceMotionAvailable` is false). Add
  a DEBUG-only launch argument for a synthetic source that turns the live fixes into physically
  consistent samples, so the whole pipeline runs in `sim-e2e.sh` and `replay-case6.sh`. The source
  uses a fixed mount rotation, longitudinal a = dv/dt, lateral a = v·ω from the course rate,
  gravity, noise and a few bumps. Release builds must contain no trace of it (grep the binary as
  in 1.1.1).
- **Permission:** check whether any usage description is required. Device motion through
  `CMMotionManager` should need none; only activity, pedometer and headphone motion do. Record the
  finding in the decision log.
- `trip.json` gains an optional `motion` summary block (additive). Existing tests that load a
  1.0 or 1.1 trip.json must still pass.

#### 16.3.2 Analysis (pure, nonisolated, off main, re-runnable, versioned)
The phone sits in a mount at an unknown angle, so device axes are not vehicle axes. Derive the
vehicle frame per trip from the raw data:
1. Per sample: `up = -gravity/|gravity|`, `a = userAcceleration * 9.80665` (m/s²), vertical
   `a_v = a·up`, horizontal `a_h = a - a_v·up`, yaw rate `ω_up = rotationRate·up` (rad/s,
   positive means turning left).
2. **Mount segments.** Low-pass `up` (about 1 s). Start a new segment when its angle to the
   segment's reference exceeds 10° for at least 1 s (phone moved, rotated or remounted). Per
   segment, use a fixed horizontal basis `e1` = device x axis projected onto the plane normal to
   the reference `up` (use y when x is nearly vertical), `e2 = up × e1`. `m(t)` = `a_h` in (e1, e2).
3. **Handling windows.** Mark ±1 s around any instant where rotation about a horizontal axis
   exceeds 0.5 rad/s, or where `up` changes fast. These windows are excluded from fitting,
   events and roughness. Report their share of the trip.
4. **Targets from GPS and gyro.** For consecutive valid fixes at most 2 s apart with speed
   ≥ 3 m/s: longitudinal target `Δv/Δt`, lateral target `v·ω_up` averaged over the same
   interval. Average `m` over the same interval as well.
5. **Fit.** A 2D rotation θ with `R(θ)·m ≈ (a_long, a_lat)`, closed form:
   `θ = atan2(Σ(m_x·t_y − m_y·t_x), Σ(m·t))`.
   - Also score the reflection. If it fits clearly better, use it and set a `reflected` flag. The
     synthetic tests must show that a rotation wins.
   - A global sign flip of `userAcceleration` is a 180° rotation in 2D, so the fit absorbs it
     (test this).
   - Search a time lag of −1 to +1 s in 0.1 s steps and keep the best one.
   - Require minimum excitation: at least 20 intervals with |target| ≥ 0.5 m/s². A segment with
     less is "nicht ausgerichtet". Its vertical and roughness results remain; its long and lat
     values do not.
   - **Quality:** the Pearson correlation `r_long` of the fitted longitudinal against `Δv/Δt`, and
     `r_lat` likewise. "Ausrichtung gut" means `r_long` ≥ 0.7.
6. **Vehicle frame at full rate:** `(long, lat) = R(θ)·m(t)`, `vert = a_v`. Events use a low-pass
   at about 2 Hz on long and lat. Roughness uses `vert` high-passed by subtracting its 1 s
   moving average.
7. **Events** (only in aligned, stable time):
   - Starke Bremsung: long ≤ −3.0 m/s² for at least 0.3 s. "Sehr stark" when the peak is
     ≤ −5.0 m/s².
   - Starke Beschleunigung: long ≥ +2.5 m/s² for at least 0.5 s.
   - Starke Querbeschleunigung: |lat| ≥ 3.0 m/s² for at least 0.5 s, with left or right.
   - Bodenwelle/Schlagloch: |vert_hp| ≥ 4.0 m/s² at speed ≥ 3 m/s, merged within 1 s. This one
     also counts in unaligned segments.
   - Each event stores start, end, peak, peak time, position interpolated from the fixes, speed,
     and the street from the road analysis when available.
8. **Roughness per 100 m driven** (speed ≥ 5 m/s, stable time): RMS of `vert_hp`. Four classes,
   glatt, normal, uneben and sehr uneben, from constants in one file. The thresholds are a first
   guess, to be calibrated on the first real drive; say so in the decision log and in the info text.
9. **Summary:**
   - max braking, max acceleration, max lateral left and right (m/s² and g);
   - event counts per kind;
   - roughness shares by distance and the 5 roughest stretches (street, position);
   - motion coverage (share of trip time with samples) and the number of sensor gaps;
   - segments, alignment quality, `r_long`, `r_lat`, lag, handling share.
10. Run at stop off the main actor through the existing analysis queue, and again on
    "Neu auswerten". Cache the full result (events, per-stretch roughness, a display series) in a
    sidecar file next to `motion.bin`. One hour at 100 Hz (360k samples) must analyze in well
    under 2 s in a release-mode test.

#### 16.3.3 Tests (synthetic generator, physics first)
- **Generator:**
  - vehicle trajectory: accelerate, cruise, left turn, right turn, a hard brake of −6 m/s² to a
    stop, bumps;
  - device samples through a random mount rotation, plus one mount change halfway;
  - CoreMotion conventions: gravity points down in device axes; rotation rate follows the
    right-hand rule;
  - noise: 0.05 g on the accelerometer, 0.01 rad/s on the gyro, engine vibration;
  - 1 Hz GPS fixes with speed noise and 0.3 s latency.
- **Assert:**
  - both segments are aligned, with `r_long` ≥ 0.9;
  - max braking within ±0.3 m/s² of the truth and max lateral within ±0.4;
  - event counts are exact;
  - bumps are found at the right time ±0.2 s;
  - the mount change is detected;
  - a negated `userAcceleration` gives the same results;
  - the reflection is not preferred;
  - a loose phone (random handling rotations) produces no hard-brake events.
- File: round trip, truncated tail, append after resume, bytes per hour.
- Engine: start, stop and resume with the scripted source, the off-main delivery check, and the
  setting off (no file).
- Old trip compatibility: 1.0 and 1.1 fixtures load, save and export unchanged.
- E2E: `sim-e2e.sh` and `replay-case6.sh` with the synthetic source. `motion.bin` exists, the
  sample count is about rate × duration (±5 %), the analysis is aligned with `r_long` ≥ 0.9, and
  the max deceleration matches the replayed GPS within tolerance. `parent-compat.sh` passes
  unchanged.
- Device proof needs a real drive. `docs/ANLEITUNG.md` carries a first-drive checklist:
  - a 10 minute drive with the phone in the mount, locked for part of it;
  - export the ZIP;
  - expected: motion coverage near 100 % also while locked, "Ausrichtung gut", plausible braking
    values.
  - If coverage drops while locked, that is a finding to fix, not to hide.

#### 16.3.4 UI and export
- **Trip detail:**
  - "Fahrdynamik (Bewegungssensor)" with the numbers above, every number with an info text that
    states its exact rule;
  - a Swift Charts line of longitudinal acceleration over time (min/max envelope per pixel
    column so peaks survive) with the events marked;
  - a quality line ("Ausrichtung gut · r = 0,93 · Sensordaten für 99 % der Fahrzeit").
  - Without motion data, the old "Fahrdynamik (ca.)" section stays as it is.
  - "Fahrbahn (Bewegungssensor)": shares by class, bump count, the roughest stretches.
  - Trip map: event markers (Bremsung, Beschleunigung, Querbeschleunigung, Bodenwelle) with
    calm glyphs and a toggle.
- **Settings:** the two motion settings, with the storage per hour stated ("etwa 22 MB pro Stunde
  bei 100 Hz") and the used storage.
- **Export:**
  - per trip "Sensordaten (CSV)": full rate, raw channels plus long, lat, vert and the aligned flag;
  - JSON: the `motion` summary and the events;
  - GPX: events as waypoints with a type; GeoJSON: events as Points;
  - `trips.csv`: new trailing columns;
  - ZIP: `motion.bin` per trip plus `MOTION-FORMAT.md`.
  - The fixes CSV is unchanged, so parent compatibility holds.
- Invoke the four design skills before the UI work.
- Optional P2, only if everything else is verified: a live g-dot in the expanded HUD from an
  online fit over the last 3 minutes.

---

### 16.4 Live Activity and Dynamic Island (idea 10)

- **Target:** a widget extension `SpurWidgets` with an `ActivityConfiguration`. The shared
  `ActivityAttributes` file is compiled into both targets. The app gets `NSSupportsLiveActivities`.
  No push, no App Group.
- **The extension must build without the gitignored font.** Bundle the font into the extension
  when present (same install script) and fall back to the system font otherwise. Test both builds.
- **Content:**
  - static: trip id, start time;
  - state: distance in m, speed in m/s, GPS accuracy, road type now, current speed limit (from 7,
    when shown), state (recording, gap or paused, poor accuracy), the units setting.
  - Elapsed time is `Text(timerInterval:)`, so it ticks without updates.
- **Presentations:**
  - lock screen: red dot, elapsed, distance, speed, GPS chip;
  - Dynamic Island compact: red dot plus elapsed on the leading side, distance on the trailing
    side; minimal: the red dot;
  - expanded: elapsed, distance, speed, GPS ± m, road type, limit sign.
  - Dark, accent `#1C69D4`, same design language. Tapping opens the Fahrt tab.
- **Lifecycle (check every point against Apple's current ActivityKit docs and record the findings
  in the decision log):**
  - Start with recording, only in the foreground. `Activity.request` from the background is not
    allowed without push-to-start.
  - After a background relaunch or resume: reattach to the existing activity by trip id. If none
    exists, start one the next time the app is active.
  - Update at most about every 10 s or on a state change, also from the background.
  - Set `staleDate` to now + 2 min on every update, so a killed app shows a stale state ("Keine
    Aktualisierung", greyed out) instead of frozen numbers.
  - At launch, end orphaned activities whose trip no longer records.
  - On stop, end with the final state ("Fahrt beendet · 12,4 km · 23 min") and dismiss after
    5 min.
  - Know the system cap on activity duration (about 8 h). When it ends a running activity, do not
    fight it, also after a relaunch: the given-up trip is remembered until the trip ends.
- **Disabled:** when the user disabled Live Activities, or `areActivitiesEnabled` is false,
  everything fails silently. Setting "Live-Aktivität anzeigen" (default on).
- **Tests:**
  - the pure state builder (units, rounding, stale and state mapping);
  - the controller with an injected activity API fake (start only in the foreground, reattach,
    throttle, orphan cleanup, end on stop).
  - Simulator screenshots: the Dynamic Island compact view from the home screen during a
    recording (`simctl io screenshot`), and the lock screen if reachable.
  - Device: B0 proves the install. The look on the real lock screen goes on the first-drive checklist.

---

### 16.5 Coordination and review
- One writer in the repository at a time. Independent checks run from a separate clone on a
  separate simulator, so they never share build products or simulator state with the main build.
- B1, B4 and B5 are each reviewed when done; review findings come before new work.
- Install on the phone at every green milestone with `scripts/install-device.sh`; data is kept.

## 17. Version 1.3: live details panel

Requirement: the acceleration data and all other trip details are visible in the live view too, and the running trip in the history opens with its details. The data was missing in the live view (not in the trip details); layout: a panel pulled up over the map, the HUD stays as it is. Scope is exactly this; ideas 11 to 21 and the earlier lists stay unbuilt. Sections 0 to 16 still apply.

### 17.0 Rules (unchanged house rules apply)

- One writer.
- The four design skills come before UI work.
- UI copy is German. No em or en dash.
- Apple frameworks only.
- Never weaken a test.
- `motion.bin` stays byte-identical, and the golden tests stay green.
- **Version 1.3.0 (5).** Every build that goes to the phone gets a new build number from now on; four commits shared "1.2.0 (4)", so the label did not identify the build.
- Install on the phone only when no trip is recording.

### 17.1 The panel

- **Where:** a pull-up panel over the live map, available while recording.
  - The HUD card stays unchanged and glanceable, and Stop stays the primary action.
  - It opens by swiping up on the HUD card or with a visible handle.
  - Title "Live-Details" with a way to close it.
  - **Two heights:**
    - Medium: the sensor block of 17.2a, with the map still visible above it.
    - Large: every section.
- **Same names, order, units and info texts as "Fahrt-Details"**, so the driver recognises them.
  - Numbers change smoothly, never jumpy.
  - The passenger note stays.
- **Outside a recording:** the panel is not offered, or it shows a designed state, never an empty or broken one.

### 17.2 Contents

**a) Fahrdynamik live (sensor), at the top:**
- a g circle (friction circle) with the current horizontal acceleration as a dot, a short trail of about 2 s, and peak marks per direction;
- current longitudinal and lateral acceleration in m/s² and g;
- Höchstwerte so far: Bremsen, Beschleunigen, Quer links, Quer rechts;
- Starke Ereignisse so far: Bremsungen, Beschleunigungen, Querbeschl. links and rechts, Stöße, with the trip analysis thresholds;
- Längsbeschleunigung over the last 60 s (rolling), with events marked;
- the status line: alignment state and sensor share.

**b) Fahrbahn live:**
- the class of the last finished 100 m stretch;
- the shares so far and the jolt count.

**c) Every other "Fahrt-Details" section that means something live:**
- Übersicht;
- Streckenart;
- Kreuzungen und Verkehrszeichen (counts, current street, current limit);
- Geschwindigkeit (Ø in Fahrt, max, chart of the trip so far);
- Höhe, Stopps, Tag und Nacht;
- GPS-Qualität (current accuracy, rate, median, P95, shares within 5 m and 10 m);
- Orte und Straßen;
- Ereignisse (manual markers).

Leave out only what has no live meaning, and record each exception with its reason in the decision log.

**Use the same statistics code** on the fixes so far, off the main actor, throttled to at most once per 5 s. The panel's numbers at Stop must equal the trip details' numbers (test it).

### 17.3 Live alignment (the hard part)

- **Where the code lives:** the live estimator is a pure Domain type with no UI and no CoreMotion.
  - It is fed samples and fixes, and it reuses the `MotionAnalysis` code (mount segments, Procrustes fit, gains, event and jolt detectors) instead of a second implementation.
  - That way an independent physics check can compile it with its own driver and replay the suite drives through it.
- **Before alignment:**
  - Show only the horizontal magnitude: no signed longitudinal or lateral values, and no left or right.
  - Show a status such as "Ausrichtung läuft (braucht Anfahren und Bremsen)".
  - Never show a wrong sign.
- **When alignment lands:**
  - Use the same acceptance criteria as the trip analysis.
  - Apply the rotation back to the samples since the segment start (a buffer, or re-read `motion.bin`), so peaks and counts cover the whole trip.
  - A remount or swivel (new mount segment) drops back to unaligned until it re-aligns.
- **Agreement with the trip analysis**, tested on the physics suite drives and the motion-e2e freeway drive:
  - live peaks within 0.3 m/s² of the post-trip values;
  - live event counts equal, or different only by stated, explained cases.
  - Put the agreement table in docs.

### 17.4 Data path and cost

- **One CoreMotion stream.** Fork to the estimator inside the `MotionRecorder` handler, and never block the file write.
- **Separate observable for panel values.** Panel values live in their own observable, read only by the panel.
  - `engine.live` / `LiveSnapshot` stays at its current rate.
  - The map must not re-evaluate at sensor rate.
- **Redraw rates:**
  - the g circle at most 10 to 15 Hz;
  - everything else at most 1 Hz;
  - nothing is published while the panel is closed or the app is in the background.
- **Measure and report:**
  - Main-thread busy with the panel open (medium and large), against the 12.4 to 13.8 % baseline (20 s `sample` profile).
  - CPU time per minute with the screen locked for 10 minutes, compared with 1.2.0 (4).
  - The estimator's extra cost while locked should stay small next to the recorder's. If it does not, say why.

### 17.5 Trip details: say why sensor data is missing

Today `TripDetailView` silently falls back to the GPS "Fahrdynamik" approximation whenever `record.motion` is nil. The user cannot tell an old trip from a broken one.

- **Show the reason** in the section:
  - Wird ausgewertet;
  - Bewegungssensor war ausgeschaltet;
  - Fahrt vor Version 1.2 aufgenommen;
  - Keine Sensordaten, with the cause from `motionHealth` (open failed, gave up, sensor not available).
- Keep the GPS approximation below the reason.

### 17.6 Tests and evidence

- **Unit tests:**
  - the estimator against `MotionAnalysis` on the suite drives (the agreement table);
  - no sign shown before alignment;
  - a remount drops alignment;
  - the panel statistics at Stop equal the trip details.
- **Simulator:**
  - `SpurSynthMotion` drives the panel, and `ui-flow` opens it at both heights.
  - Screenshots 24 (medium, aligned), 25 (large) and 26 (unaligned state), all with real values.
- **Performance:** the numbers from 17.4.
- **Docs:** add a first-drive item to the ANLEITUNG checklist: signed values appear after the first braking, and the panel's Höchstwerte match the trip details after Stop.
- **Review:** an independent physics check replays the estimator before 1.3 is accepted.

### 17.8 The running trip opens from the history

Requirement: the running trip in the history can be tapped and opens its details.

Today the "Läuft" row in Historie (`HistoryView`, `RunningTripRow`) only switches to the Fahrt tab.

**Change:** tapping it opens the "Fahrt-Details" screen of the running trip, updating live.
- The map shows the trail so far and the position.
- Every section is there, including the sensor sections from 17.2a and 17.2b.
- The numbers equal the panel's at the same moment, because there is one live model that both the panel and this screen read.

**Rules for the running trip:**
- "Löschen" is not offered while recording.
- Renaming and the note work.
- Export of a running trip is either left out or clearly marked as a partial trip; decide which and record it in the decision log.
- When the trip stops while the screen is open, it becomes the normal finished detail without leaving the screen. The values switch to the final analysis smoothly, with no jump back to the history.

**Tests and evidence:**
- The tap opens the live detail.
- Stopping while it is open hands over to the finished trip.
- Add the flow to `ui-flow`, and take screenshot 27 (the running trip's details).

### 17.9 Speed limit: say why there is none

Requirement: when the live view shows no speed limit, the driver can see why.

Outside the Dallas pack the sign is often missing. By SPEC 16.2 the HUD sign hides in any of these cases:
- no `maxspeed` tag on the way;
- no stable match yet;
- accuracy worse than 15 m;
- a parallel candidate with a different limit;
- no road tiles (outside the pack, Overpass failed or off).

The driver cannot tell which case applies.

- **HUD:** keep the rule. A sign or nothing, never a guessed default.
- **Panel (17.2c, Kreuzungen und Verkehrszeichen):** show the current limit state with its reason:
  - "45 mph laut OSM";
  - "Kein Tempolimit in OSM eingetragen";
  - "Straße noch nicht sicher erkannt";
  - "GPS zu ungenau";
  - "Zwei Straßen mit verschiedenem Limit";
  - "Keine Straßendaten hier (Kacheln fehlen)".
- **Per trip** (trip JSON and Fahrt-Details): store the driving-time share with a shown limit and the share per hide reason. After a drive this shows whether the cause is OSM, the matcher or the tiles.
- **Check a real trip that showed no limit:**
  - Do the ways driven there carry `maxspeed` in the loaded tiles?
  - Did the trip have tiles at all?
  - Did the divided-road candidates hide the sign? The opposite carriageway has the opposite bearing, so it must not count as a competing candidate.
  - If it was the matcher, that is a bug: fix it with a test.

### 17.7 First, before the panel

The first real drive with the 1.2 sensor path is checked before the panel work, since every earlier check used `SpurSynthMotion`.

- **Check:** after the trip stops and the phone is reachable, pull the app container read-only (no install, no writes) and check `motion.bin`, `trip.motion` and `motionHealth`.
- **If the trip has no sensor section,** that is P0 and comes before 17.1.
- **Meanwhile,** start with 17.0, the SPEC text, and 17.3 (the Domain estimator and its tests).

## 18. Version 1.4: light map, traffic, search, discovery route

Requirement: a traffic view; a search for places to navigate to; planning of a route through what is still undriven, with what can be found there (many signals, many junctions and so on); and a light map style like common web maps, because the dark one lacks contrast. Sections 0 to 17 still apply.

### 18.0 Rules and order

House rules are unchanged:
- one writer;
- the four design skills before UI work;
- German UI copy, no em or en dash;
- Apple frameworks only;
- never weaken a test;
- `motion.bin` byte-identical;
- install only when no trip records.

**Version 1.4.0**, with a new build number for every phone build.

**When to start:** finish what 1.3 still owes first: the 17.4 numbers and N1/N2. Then start 18.1.
- The live gate rule comes from the independent physics check once it is proven on recorded drives.
- It lands as 17.10 in a 1.3.x build, in between 1.4 phases. 1.3 is accepted only after that.

**Order:** 18.1 light map, 18.2 traffic, 18.3 search, 18.4 scenario finder, 18.5 discovery route, 18.6 evidence.

**Parent reference** (read-only, not public): the parent already has this feature for the web:
- SPEC section 8, "Scenario finder and suggestions": feature table, scoring, top 10 with a plain reason, up to 9 waypoints, deep links, "Nächste unbefahrene Strecke";
- `src/lib/scenario/` (`rules.ts`, `nearest.ts`, `route.ts`, `text.ts`) and its tests.

Port the rules and names. Do not invent a second vocabulary.

### 18.1 Light map (Hell / Dunkel / Automatisch)

**Setting.** "Kartenstil" with three choices: Automatisch, Hell, Dunkel.
- The default is **Automatisch**: light from sunrise to sunset at the current position (use `SunPosition`, which already exists), dark at night. A light map at night blinds the driver; the dark map lacks contrast in daylight.
- The switch happens once at sunrise or sunset with a crossfade, never back and forth (hysteresis).

**The whole app follows,** not only the base map.
- Live, history, details, panel, sheets and settings get light variants, as tokens in `Theme`.
- Today `SpurApp` forces `.preferredColorScheme(.dark)`; that goes.
- If the design skills argue for keeping the HUD dark over a light map, you may do that, but record it in the decision log with the reason.

**Contrast, measured, not eyeballed:**
- text at least 4.5:1;
- map overlays at least 3:1 against the light base map: trail, coverage colours (one-way and both-way), chevrons, arrow, speed limit sign, markers.
- Put the measured ratios in docs.

**Dark contrast too.** The dark map lacks contrast.
- Check whether the dark style uses a muted emphasis or a dimming layer that flattens the roads.
- Raise road contrast where it does not hurt night use.
- Show before and after in screenshots.

**Evidence:**
- screenshots of live, panel medium, history, details and settings, in light, on the iPhone 16 simulator;
- ui-flow runs once in light and once in dark.

### 18.2 Traffic

- **Toggle:** a "Verkehr" map layer toggle on the live map and in the plan views (18.3 to 18.5). It is remembered, off by default, and uses `showsTraffic` of the MapKit standard style.
- **Colour clash:** traffic is green, orange and red, and so are parts of the coverage and speed encodings. No hue may mean two things at once.
  - While traffic is on, the coverage overlay switches to an encoding that cannot be confused with it (for example dimmed, or another hue family).
  - Record which in the decision log, with a screenshot.
- **Honest state:** say when traffic is unavailable (offline, or no data for the region), never a silent empty layer.

### 18.3 Search ("Suchen")

**Where:** the design skills decide, and the decision log records it. The suggested layout is a fourth tab "Planen" that holds search (18.3) and the discovery route (18.4, 18.5). The Fahrt tab only shows a small chip for an active plan. One primary action per view.

**How it works:**
- `MKLocalSearchCompleter` suggestions while typing.
- `MKLocalSearch` results as a list and as pins.
- Tapping a result opens a place card: name, address, distance, and ETA by `MKDirections`.

**Actions on the place card:**
- **Navigieren** (primary): hand off to Apple Maps by `MKMapItem.openMaps` with driving directions.
- **In Google Maps öffnen:** a URL hand-off only, no SDK.
- **Route in Spur zeigen:** the `MKDirections` polyline on Spur's map over the coverage layer.
- **Als Ziel der Entdeckerroute:** see 18.5.

**Recording while handed off:** Spur keeps recording in the background.
- A recorded trip showed three "background" gaps of 5 to 7 s.
- Test on the device: drive or simulate at least 10 minutes with Apple Maps in front while Spur records.
- Report the gaps against a 10-minute trip with Spur in front. If the hand-off adds gaps, fix that before 18.3 is done.

**Privacy:** queries go to Apple only. Nothing about the user goes into a URL beyond the destination and waypoints.

### 18.4 Scenario finder ("Was gibt es zu entdecken")

Port parent SPEC 8 to Spur's own road data:
- **Data:** `RoadNetwork`, `RoadFeatures` and the coverage merged over all trips (`RoadCoverage.merge`).
- **Inputs:**
  - feature chips (multi-select): Ampeln (many per km), schiefe Kreuzungen, Stoppschilder, Kreisverkehre, Bahnübergänge, Auffahrten, schnelle Straßen, Mautstraßen, Frontage-Übergänge;
  - only what Spur's data can decide today. Leave out what needs data Spur does not load (for example lane counts, if the tiles lack them) and list it in the decision log;
  - a direction preference: "egal" or "nur fehlende Richtung";
  - a radius from the current position or from a searched place.
- **Scoring:** as the parent: feature density x not yet driven in the requested direction x a distance penalty.
- **Output:** the top 10 clusters on the map and in a list, each with a plain reason in the parent's style, for example "3 Ampeln, 1 schiefe Kreuzung, Richtung Nord fehlt".
- **"Nächste unbefahrene Strecke":** one tap picks the nearest legal undriven segment-direction that matches the chips, and offers the 18.3 actions.
- **Road data:**
  - inside the Dallas pack, use the pack;
  - elsewhere, use the tile cache plus Overpass for the missing tiles of the radius, at most 16 tiles per query, with a visible loading state and the existing failure texts;
  - never a silent empty result: say "Keine Straßendaten hier" or "Nichts Unbefahrenes mit diesen Merkmalen im Umkreis".

### 18.5 Discovery route ("Entdeckerroute")

**Inputs:**
- start: the current position, or a searched place;
- mode: **Rundkurs**, back to the start, or **Zum Ziel**, a searched place, with a detour budget;
- budget: length in km, or time in minutes, estimated from `maxspeed`, else the road class speeds;
- the feature chips and the direction preference of 18.4.

**Planner:** a pure Domain type with no UI, MapKit or network.
- It works on the road graph: legal directions only, with `oneway` respected.
- Leave out `access=private/no`, `service` except the kept kinds, `track` and `construction`.
- **The goal:** maximise new metres in the wanted direction plus the weighted features, within the budget.
- **Driven edges** add nothing; driving them again only costs.
- **Turn restrictions:** if the tiles do not carry restriction relations, avoid U-turns except at dead ends, and say "Abbiegeverbote nicht geprüft" in the route card. Record this in the decision log.
- **Deterministic:** the same inputs give the same route.

**Output:**
- the route on Spur's map over the coverage, with up to 3 alternatives;
- a route card, for example: "34 km, davon 21 km neu (62 %), 18 Ampeln, 9 schiefe Kreuzungen, 3 Stoppschilder, etwa 48 min";
- the waypoints in order.

**Follow it:**
- **In Spur (primary):** "Route anzeigen" keeps the planned line on the live map during recording. Driven parts fade as coverage fills, and the next waypoint is marked. No voice and no turn-by-turn in 1.4.
- **Hand-off:**
  - **Apple Maps:** with all waypoints if `MKMapItem.openMaps` on iOS 26 takes them in order (verify it on the device). Else hand off to the first waypoint and say so.
  - **Google Maps URL:** up to 9 waypoints, the parent's limit.
  - **GPX route export.**

**Acceptance:**
- **Legality:** 0 edges against `oneway`, 0 excluded ways, and no U-turn except at a dead end, on every test graph and on the Dallas pack.
- **Budget:** the route length is within ±5 % of the budget (Rundkurs), or within the detour budget (Zum Ziel).
- **Quality:** on small synthetic graphs, the result is at least 90 % of the brute-force optimum. On the Dallas pack, it is better than the baseline of the parent's method (top clusters ordered by nearest neighbour plus 2-opt, joined by shortest paths) on new metres and features.
- **Plan versus drive (E2E):**
  - Plan a route on the Dallas pack, drive it with the simulator GPS (sim-e2e infrastructure), and stop.
  - The trip's road analysis must count the planned features within ±10 %, and the new coverage must match the predicted new metres within ±10 %.
- **Speed:** planning a 50 km Rundkurs in a 15 km radius takes at most 3 s on the iPhone 16. Measure it on the device, and report the Mac and simulator numbers too.

### 18.6 Tests and evidence

- **Unit tests:** every rule above, plus the ported parent scenario tests where they apply.
- **ui-flow:** light and dark; traffic on and off; search, place card and "Route in Spur zeigen"; finder and its top 10; plan a Rundkurs, show it and start a recording with it.
- **Screenshots from 28 on,** iPhone 16 and 17 Pro.
- **ANLEITUNG:**
  - a "Planen" section;
  - a first-drive checklist item: a planned route is shown while recording, and the trip's counts match the plan.
- **Review:** the screenshots and the planner are reviewed (with an independent check of the legality and budget tests) before acceptance.
