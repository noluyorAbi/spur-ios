# Roadmap

Ideas for where Spur goes next. Nothing here is promised or scheduled; the order is the order
the work makes sense in. Each idea says why it matters, how it would be built, roughly how big
it is, and when it counts as done.

Sizes: S is a day or two, M is about a week, L is several weeks.

## Now: prove 1.4 on real drives

Before anything new, the current release has to hold up on the road. Version 1.4 rewrote the
automatic pause (location only), removed the motion activity source, and made the route planner
far more tolerant of slow OpenStreetMap servers. All of it is tested in the simulator; none of
it is confirmed in a car yet.

- Drive two or three normal trips: start in the Fahrt tab, stop in a car park, wait in a jam on
  a major road, plan a loop in Planen.
- Export the trips and replay them through the unit tests as fixtures, so every bug found on the
  road becomes a test before it is fixed.

Done when: three real trips without a crash, a car park stop paused, a jam not paused, and a
planned route found within a minute.

## Next

### 1. Plan without waiting (M)

Today a route needs road data from public Overpass servers, and a cold area took over four
minutes for six tiles. That is the single worst moment in the app.

- Ship an offline road pack for a home region, built by `scripts/build-osm-pack.sh`, so the
  planner and the coverage map work instantly and without a connection.
- Fetch missing tiles in the background (BGTaskScheduler, on Wi-Fi and while charging) for the
  area around recent trips and around the place last searched.
- Show which tiles are ready on the map, so a gap in the data is visible before planning.

Done when: a loop in a known area plans in under five seconds in flight mode.

### 2. Past coverage on the live map, on by default (S)

The live map can already show the roads driven before, but it is easy to miss. Driving the same
street twice by accident is exactly what Spur exists to prevent.

- Show past coverage under the live trail by default, dimmed, with one tap to hide it.
- Keep the direction colours (amber one way, green both ways) so a half driven road reads as
  "come back the other way".

Done when: a new user sees past roads on the first drive without opening a setting.

### 3. Goals and progress (M)

A number gives a reason to open the app again: "38 % of this district driven".

- Coverage share per district and per city, from OpenStreetMap administrative boundaries.
- A short list of the nearest undriven streets, each one tap away from a route.
- A history line: how much new road each trip added.

Done when: the Historie tab shows per area progress and every trip shows its new kilometres.

## Later

### 4. Guidance during the drive (L)

A route currently leaves the app for Apple Maps or Google Maps, which know nothing about
coverage and quietly reroute over roads already driven.

- Turn by turn prompts on the Fahrt screen for discovery routes, from MapKit directions between
  the planner's waypoints.
- Replan automatically when the car leaves the route, preferring undriven roads again.
- Large, glanceable type; the passenger rule stays until CarPlay exists.

Done when: a 30 km loop can be driven start to finish without leaving Spur.

### 5. CarPlay (L)

The app is operated by the passenger today. On the car screen, the map and the next undriven
turn become safe to use alone.

- A CarPlay map template with the coverage overlay and the active route.
- Needs the CarPlay navigation entitlement from Apple, which is the long pole.

### 6. Backup and sync (M)

All trips live only on the phone. Losing the phone loses everything.

- Optional iCloud Drive backup of the trip folders, unchanged on disk (raw fixes stay raw).
- Restore on a new phone, with a check that every file arrived.
- No server of our own, keeping the privacy promise in the README.

### 7. Battery and heat (M)

Full rate GPS and motion sampling for hours is expensive.

- Measure first: energy per hour of recording on two phone models, logged in the repo.
- Lower the motion rate while the car stands, never thin the GPS fixes on disk.

## Giving back to OpenStreetMap

Spur reads road data from OpenStreetMap, and a car that drives every street sees where that map
is wrong. These ideas send something back.

- **Missing roads.** A drive along a stretch with no OSM way nearby is likely a road the map does
  not have. Collect those stretches and offer them as a GPX trace or an OSM note the driver can
  review and submit. Nothing is uploaded without the driver's explicit action.
- **Wrong attributes.** Average speeds far above a mapped limit, or a road always driven in only
  one direction while OSM says two way, are hints worth a note.
- **Public GPS traces.** Make it one step to upload a chosen trip to the OSM GPS trace archive,
  which mappers use to align roads.

## Opening parts of the code

The app is published to be read and is not licensed for reuse (see `LICENSE`). Some parts could
be useful on their own, and opening them is a separate decision for each:

- **Coverage engine.** Map matching, direction aware road coverage and divided road pairing are
  pure Swift with no UI. As a standalone Swift package with a permissive license, others could
  build coverage features without the app.
- **Discovery planner.** The loop and goal planner that prefers undriven roads.
- **Motion format.** `docs/MOTION-FORMAT.md` already documents the raw motion file; a small
  reader library in Swift and Python would let others analyse exported trips.
- **Test fixtures.** Synthetic drives and the physics tables, so other projects can check their
  own sensor maths against the same cases.

Before any of this: decide the license per package, keep the app itself all rights reserved,
and set up a contributor agreement if outside pull requests are ever accepted.

## Ideas without a plan yet

- Apple Watch complication with the current trip's new kilometres.
- Shortcuts actions: start a trip, plan a loop of N km.
- A shareable map image of an area's coverage, with no track or home location in it.
- Night and rain detection to tag trips by conditions.

Suggestions are welcome as GitHub issues.
