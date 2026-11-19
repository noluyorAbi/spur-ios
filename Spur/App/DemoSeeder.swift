#if DEBUG
import Foundation

/// Creates four clearly synthetic demo trips (`-SpurSeedDemo YES`) for screenshots and UI review.
///
/// The fixes are generated from hand-placed waypoints and a speed profile in code; none of it is
/// recorded data. Every demo trip carries `isDemo = true`.
enum DemoSeeder {
    struct Leg {
        var to: (Double, Double)
        /// Cruise speed in km/h on this leg.
        var kmh: Double
        /// Seconds standing still at the end of the leg.
        var stopAfter: Double = 0
    }

    struct Plan {
        var startOffsetDays: Double
        var startHourUTC: Double
        var start: (Double, Double)
        var legs: [Leg]
        var places: [(fraction: Double, locality: String, street: String)]
        var events: [(fraction: Double, tag: TripEvent.Tag)]
        /// Seconds without fixes at this fraction of the trip (a tunnel), 0 for none.
        var gapAt: Double = 0
        var gapSeconds: Double = 0
        var note: String?
    }

    /// Debug: the drives of a parent oracle file as finished demo trips (once per file).
    static func importDrives(_ path: String, into store: TripStore) {
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard !store.index().contains(where: { $0.note?.hasPrefix("Import \(name)") == true }),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for (k, d) in (root["drives"] as? [[String: Any]] ?? []).enumerated() {
            let fixes: [Fix] = (d["fixes"] as? [[String: Any]] ?? []).compactMap { f in
                guard let t = (f["t"] as? NSNumber)?.int64Value, let lat = (f["lat"] as? NSNumber)?.doubleValue,
                      let lon = (f["lon"] as? NSNumber)?.doubleValue else { return nil }
                return Fix(timestampMs: t, latitude: lat, longitude: lon, horizontalAccuracy: (f["accuracy"] as? NSNumber)?.doubleValue,
                           speed: (f["speed"] as? NSNumber)?.doubleValue, course: (f["heading"] as? NSNumber)?.doubleValue)
            }
            guard let first = fixes.first, let last = fixes.last else { continue }
            var record = TripRecord(startedAt: first.date, isRecording: false)
            record.endedAt = last.date
            record.isDemo = true
            record.note = "Import \(name), Fahrt \(k + 1)"
            record.usableAccuracyLimit = StatsConstants.defaultUsableAccuracy
            let analysis = TripAnalyzer.analyze(fixes: fixes, places: [])
            record.gaps = analysis.gaps
            record.statistics = analysis.statistics
            record.preview = TrailGeometry.preview(fixes, config: .default)
            guard (try? store.create(record)) != nil, let writer = try? store.openWriter(record.id) else { continue }
            for f in fixes { try? writer.append(f) }
            writer.close()
        }
    }

    /// Debug: a drive along real downtown Dallas roads (the fastest path between two fixed points
    /// on the bundled pack), 1 Hz at 11 m/s, with 45 s of fixes left out in the middle: a gap the
    /// fill can suggest a route for (SPEC 18.8). Once.
    static func seedGapDemo(into store: TripStore, now: Date = Date()) {
        guard !store.index().contains(where: { $0.note == "Demofahrt mit Lücke" }), let pack = RoadPack.bundled() else { return }
        let a = LatLon(lat: 32.7767, lon: -96.7970), b = LatLon(lat: 32.7905, lon: -96.8050)
        var parts: [OSMElements] = []
        for key in TileKey.within(radius: 2500, ofLat: a.lat, lon: a.lon) {
            if let e = try? pack.elements(for: key) { parts.append(e) }
        }
        let net = RoadNetwork(.merged(parts))
        let g = DiscoveryPlanner.graph(segments: net.segments, features: [], chips: [], onlyMissing: false) { _, _ in false }
        // The nearest arcs can be a dead-end stub; take the first pair of ends that connects.
        let starts = GapFiller.snap(GapFiller.End(position: a, accuracy: 100), g, leaving: true).prefix(6)
        let ends = GapFiller.snap(GapFiller.End(position: b, accuracy: 100), g, leaving: false).prefix(6)
        var found: (GapFiller.Snap, GapFiller.Snap, [Int])?
        search: for s in starts {
            for e in ends {
                if let p = GapFiller.path(g, from: s, to: e, penalty: [:], perMetre: { GapFiller.secondsPerMetre(g, $0) }), p.length > 1200 {
                    found = (s, e, p.arcs)
                    break search
                }
            }
        }
        guard let (s, e, arcs) = found else { return }
        let line = GapFiller.coords(g, arcs, s, e)
        let total = OSMGeo.lineLength(line)
        let start = now.addingTimeInterval(-7200)
        var fixes: [Fix] = []
        var x = 0.0, t = 0.0
        while x < total {
            let p = OSMGeo.point(along: line, offset: x)
            let q = OSMGeo.point(along: line, offset: min(total, x + 5))
            // The gap: about 45 s around the middle of the drive.
            let mid = total / 2
            if !(x > mid - 250 && x < mid + 250) {
                fixes.append(Fix(timestampMs: Int64((start.timeIntervalSince1970 + t) * 1000), latitude: p.lat, longitude: p.lon,
                                 horizontalAccuracy: 5, speed: 11, course: OSMGeo.bearing(p, q)))
            }
            x += 11
            t += 1
        }
        guard let first = fixes.first, let last = fixes.last else { return }
        var record = TripRecord(startedAt: first.date, isRecording: false)
        record.endedAt = last.date
        record.isDemo = true
        record.note = "Demofahrt mit Lücke"
        record.usableAccuracyLimit = StatsConstants.defaultUsableAccuracy
        let analysis = TripAnalyzer.analyze(fixes: fixes, places: [])
        record.gaps = analysis.gaps
        record.statistics = analysis.statistics
        record.preview = TrailGeometry.preview(fixes, config: .default)
        guard (try? store.create(record)) != nil, let writer = try? store.openWriter(record.id) else { return }
        for f in fixes { try? writer.append(f) }
        writer.close()
    }

    /// Debug: 300 driven blocks (one way and both ways alternating, so they do not chain) around
    /// downtown Dallas, and a recording trip of 2 h ending now that the engine resumes.
    static func seedStress(into store: TripStore, now: Date = Date()) {
        guard !store.index().contains(where: { $0.note == "Stress coverage" }) else { return }
        let lat0 = 32.7767, lon0 = -96.797
        let dLat = 100 / 110_540.0, dLon = 100 / (111_320.0 * cos(lat0 * .pi / 180))
        func p(_ i: Int, _ j: Int) -> LatLon { LatLon(lat: lat0 + Double(j - 5) * dLat, lon: lon0 + Double(i - 8) * dLon) }
        func node(_ i: Int, _ j: Int) -> Int64 { Int64(1_000_000 + i * 100 + j) }
        var runs: [CoverageRun] = []
        for j in 0..<10 {
            for i in 0..<15 {
                runs.append(CoverageRun(wayId: Int64(9_000_000 + j), nodes: [node(i, j), node(i + 1, j)], coords: [p(i, j), p(i + 1, j)],
                                        forward: true, backward: (i + j) % 2 == 0))
                runs.append(CoverageRun(wayId: Int64(9_100_000 + i), nodes: [node(i, j), node(i, j + 1)], coords: [p(i, j), p(i, j + 1)],
                                        forward: true, backward: (i + j) % 2 == 1))
            }
        }
        var covered = TripRecord(startedAt: now.addingTimeInterval(-86_400), isRecording: false)
        covered.endedAt = now.addingTimeInterval(-86_000)
        covered.isDemo = true
        covered.note = "Stress coverage"
        var roads = RoadStatistics(analyzedAt: now)
        roads.coverage = 0.99
        roads.matchedDistance = 30_000
        covered.roads = roads
        guard (try? store.create(covered)) != nil else { return }
        try? store.saveCoverage(TripCoverage(runs: runs), for: covered.id)

        // 7200 fixes at 1 Hz, 10 m/s, back and forth over the same blocks, the last one now.
        var fixes: [Fix] = []
        let start = now.addingTimeInterval(-7200)
        var lat = lat0, lon = lon0, course = 90.0
        for k in 0..<7200 {
            if k % 150 == 0 { course = course == 90 ? 270 : 90; lat += dLat * 0.5 }
            if k % 1500 == 0 { lat = lat0 }
            lon += (course == 90 ? 1 : -1) * 10 / (111_320.0 * cos(lat0 * .pi / 180))
            fixes.append(Fix(timestampMs: Int64((start.timeIntervalSince1970 + Double(k)) * 1000), latitude: lat, longitude: lon,
                             horizontalAccuracy: 5, speed: 10, speedAccuracy: 0.5, course: course))
        }
        let recording = TripRecord(startedAt: fixes[0].date, isRecording: true)
        guard (try? store.create(recording)) != nil, let writer = try? store.openWriter(recording.id) else { return }
        for f in fixes { try? writer.append(f) }
        writer.close()
        UserDefaults.standard.set(recording.id.uuidString, forKey: RecordingEngine.recordingKey)
    }

    static func seedIfNeeded(into store: TripStore, now: Date = Date()) {
        if store.index().contains(where: { $0.isDemo == true }) { return }
        for (k, plan) in plans.enumerated() {
            try? seed(plan, index: k, into: store, now: now)
        }
    }

    // Dallas area, rough road shapes. Synthetic.
    static let plans: [Plan] = [
        Plan(
            startOffsetDays: 1, startHourUTC: 15.2, start: (32.7767, -96.7970),
            legs: [
                Leg(to: (32.7811, -96.7912), kmh: 38, stopAfter: 25),
                Leg(to: (32.7858, -96.7988), kmh: 45, stopAfter: 18),
                Leg(to: (32.7905, -96.8053), kmh: 42),
                Leg(to: (32.7961, -96.8030), kmh: 35, stopAfter: 30),
                Leg(to: (32.8010, -96.7951), kmh: 48),
                Leg(to: (32.7952, -96.7869), kmh: 40, stopAfter: 20),
                Leg(to: (32.7871, -96.7838), kmh: 44),
                Leg(to: (32.7790, -96.7880), kmh: 36, stopAfter: 15),
                Leg(to: (32.7768, -96.7968), kmh: 30),
            ],
            places: [(0, "Dallas", "Main St"), (0.35, "Dallas", "N Akard St"), (0.7, "Dallas", "Ross Ave"), (1, "Dallas", "Commerce St")],
            events: [(0.3, .construction), (0.62, .poorLaneMarking)],
            note: "Demofahrt: Innenstadt, viele Ampeln."
        ),
        Plan(
            startOffsetDays: 2, startHourUTC: 19.5, start: (32.7930, -96.8130),
            legs: [
                Leg(to: (32.8104, -96.8255), kmh: 75),
                Leg(to: (32.8467, -96.8697), kmh: 110),
                Leg(to: (32.8800, -96.8950), kmh: 115),
                Leg(to: (32.9200, -96.9020), kmh: 118),
                Leg(to: (32.9650, -96.9290), kmh: 112),
                Leg(to: (32.9905, -96.9480), kmh: 90),
                Leg(to: (32.9990, -96.9585), kmh: 55),
            ],
            places: [(0, "Dallas", "N Stemmons Fwy"), (0.4, "Dallas", "I-35E"), (0.75, "Carrollton", "I-35E"), (1, "Carrollton", "E Trinity Mills Rd")],
            events: [(0.55, .interestingScenario)],
            gapAt: 0.45, gapSeconds: 40
        ),
        Plan(
            startOffsetDays: 3, startHourUTC: 23.6, start: (33.0450, -96.6200),
            legs: [
                Leg(to: (33.0610, -96.5790), kmh: 72),
                Leg(to: (33.0790, -96.5480), kmh: 78, stopAfter: 12),
                Leg(to: (33.1040, -96.5300), kmh: 70),
                Leg(to: (33.1290, -96.5020), kmh: 80),
                Leg(to: (33.1500, -96.4810), kmh: 65),
            ],
            places: [(0, "Allen", "FM 2551"), (0.5, "Lucas", "W Lucas Rd"), (1, "Princeton", "County Rd 470")],
            events: [(0.4, .hazard)]
        ),
        Plan(
            startOffsetDays: 5, startHourUTC: 14.0, start: (32.7810, -96.8000),
            legs: [
                Leg(to: (32.7860, -96.8160), kmh: 40, stopAfter: 20),
                Leg(to: (32.7920, -96.8330), kmh: 45),
                Leg(to: (32.8010, -96.8650), kmh: 95),
                Leg(to: (32.8150, -96.9100), kmh: 105),
                Leg(to: (32.8290, -96.9480), kmh: 100),
                Leg(to: (32.8380, -96.9610), kmh: 60, stopAfter: 15),
                Leg(to: (32.8450, -96.9700), kmh: 42, stopAfter: 22),
                Leg(to: (32.8520, -96.9790), kmh: 38),
            ],
            places: [(0, "Dallas", "Elm St"), (0.3, "Dallas", "John W Carpenter Fwy"), (0.75, "Irving", "John W Carpenter Fwy"), (1, "Irving", "N O'Connor Blvd")],
            events: [(0.2, .obscuredSign), (0.85, .closure)]
        ),
    ]

    /// Deterministic pseudo random numbers (LCG), so the demo looks the same on every seed.
    struct Noise {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    static func seed(_ plan: Plan, index: Int, into store: TripStore, now: Date) throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let day = utc.startOfDay(for: now).addingTimeInterval(-plan.startOffsetDays * 86_400)
        let start = day.addingTimeInterval(plan.startHourUTC * 3600)
        var noise = Noise(state: UInt64(index + 1) * 7919)
        let fixes = generate(plan, startMs: Int64(start.timeIntervalSince1970 * 1000), noise: &noise)
        guard let first = fixes.first, let last = fixes.last else { return }

        var record = TripRecord(startedAt: first.date, isRecording: false)
        record.endedAt = last.date
        record.isDemo = true
        record.note = plan.note
        record.usableAccuracyLimit = StatsConstants.defaultUsableAccuracy
        record.context = TripContext(
            driverName: "Demo", vehicleName: "Kombi", deviceModel: AppEnvironment.deviceModel,
            systemVersion: "26.0", appVersion: AppEnvironment.appVersion, appBuild: AppEnvironment.appBuild,
            timeZoneIdentifier: "America/Chicago", batteryLevelStart: 0.92, batteryLevelEnd: 0.81,
            lowPowerModeStart: false, lowPowerModeEnd: false, authorization: .always, accuracyAuthorization: .full
        )
        let span = Double(last.timestampMs - first.timestampMs)
        func fixAt(_ fraction: Double) -> Fix {
            let t = first.timestampMs + Int64(span * fraction)
            return fixes.last(where: { $0.timestampMs <= t }) ?? first
        }
        record.places = plan.places.map { p in
            let f = fixAt(p.fraction)
            let kind: PlaceSample.Kind = p.fraction == 0 ? .start : (p.fraction == 1 ? .end : .moving)
            return PlaceSample(timestampMs: f.timestampMs, latitude: f.latitude, longitude: f.longitude,
                               kind: kind, locality: p.locality, street: p.street)
        }
        let analysis = TripAnalyzer.analyze(fixes: fixes, places: record.places)
        record.gaps = analysis.gaps
        record.statistics = analysis.statistics
        record.preview = TrailGeometry.preview(fixes, config: .default)

        try store.create(record)
        let writer = try store.openWriter(record.id)
        var previous: Fix?
        for f in fixes {
            if let p = previous, f.time - p.time > StatsConstants.gapThreshold {
                try writer.append(Gap(startMs: p.timestampMs, endMs: f.timestampMs, reason: .signal))
            }
            try writer.append(f)
            previous = f
        }
        writer.close()
        let events = plan.events.map { e in
            let f = fixAt(e.fraction)
            return TripEvent(id: UUID(), timestampMs: f.timestampMs, latitude: f.latitude, longitude: f.longitude,
                             altitude: f.altitude, tag: e.tag, note: nil)
        }
        try store.saveEvents(events, for: record.id)
        // The first demo trip carries synthetic motion (SPEC 16.3), derived from its fixes with a
        // tilted mount; the road analysis backfills its motion analysis.
        if index == 0 {
            var motionNoise = MotionSynth.Noise(state: 2026)
            let mount = MotionSynth.mount(yaw: 37, pitch: -62, roll: 8)
            let motion = try MotionFileWriter(url: store.motionURL(record.id), rateHz: 100, created: first.time)
            // The demo's legs turn within one fix, which no car does: the motion follows the course
            // smoothed over ±3 fixes, so corners stay physical (gyro and lateral agree).
            let smoothed = Self.smoothedCourse(fixes, half: 3)
            for (a, b) in zip(smoothed, smoothed.dropFirst()) {
                try motion.append(MotionSynth.between(a, b, rateHz: 100, mount: mount, noise: &motionNoise))
            }
            motion.close()
        }
    }

    /// The fixes with the course averaged (unwrapped) over ±`half` neighbours that have one.
    static func smoothedCourse(_ fixes: [Fix], half: Int) -> [Fix] {
        var unwrapped: [Double?] = []
        var last: Double?
        for f in fixes {
            guard let c = f.course else { unwrapped.append(nil); continue }
            let u = last.map { $0 + MotionAnalyzer.wrap180(c - $0) } ?? c
            unwrapped.append(u)
            last = u
        }
        return fixes.indices.map { k in
            var f = fixes[k]
            guard unwrapped[k] != nil else { return f }
            let window = unwrapped[max(0, k - half)...min(fixes.count - 1, k + half)].compactMap { $0 }
            let mean = window.reduce(0, +) / Double(window.count)
            f.course = (mean.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
            return f
        }
    }

    /// Drives the legs at 1 Hz with smooth acceleration, stops and an optional gap.
    static func generate(_ plan: Plan, startMs: Int64, noise: inout Noise) -> [Fix] {
        var out: [Fix] = []
        var t = 0.0
        var v = 0.0
        var pos = plan.start
        var totalLength = 0.0
        var p = plan.start
        for leg in plan.legs {
            totalLength += Geo.distance(lat1: p.0, lon1: p.1, lat2: leg.to.0, lon2: leg.to.1)
            p = leg.to
        }
        var travelled = 0.0
        var gapDone = plan.gapSeconds == 0

        func emit(course: Double) {
            let acc = 3 + noise.next() * 3
            let altitude = 150 + 12 * sin(travelled / 1800) + noise.next() * 0.8
            let jitterLat = (noise.next() - 0.5) * Geo.latitudeDegrees(forMeters: 1.5)
            out.append(Fix(
                timestampMs: startMs + Int64(t * 1000), latitude: pos.0 + jitterLat, longitude: pos.1,
                horizontalAccuracy: acc, altitude: altitude, ellipsoidalAltitude: altitude - 26,
                verticalAccuracy: 4 + noise.next() * 2, speed: v, speedAccuracy: 0.3 + noise.next() * 0.4,
                course: course, courseAccuracy: 3 + noise.next() * 4,
                isSimulatedBySoftware: false, isProducedByAccessory: false
            ))
        }

        for leg in plan.legs {
            let course = Geo.bearing(lat1: pos.0, lon1: pos.1, lat2: leg.to.0, lon2: leg.to.1)
            var remaining = Geo.distance(lat1: pos.0, lon1: pos.1, lat2: leg.to.0, lon2: leg.to.1)
            let target = leg.kmh / 3.6
            while remaining > 0.5 {
                // Ease toward the cruise speed, brake before a stop.
                let brakeDistance = leg.stopAfter > 0 ? v * v / (2 * 2.2) : 0
                let goal = remaining < brakeDistance + 5 ? max(2, sqrt(2 * 2.2 * remaining)) : target
                let dv = max(-3.2, min(2.0, goal - v))
                v = max(0, v + dv)
                let step = min(remaining, v)
                let next = Geo.destination(lat: pos.0, lon: pos.1, bearing: course, distance: step)
                pos = (next.lat, next.lon)
                remaining -= step
                travelled += step
                t += 1
                if !gapDone, travelled / totalLength >= plan.gapAt {
                    // A tunnel: no fixes, the car keeps moving.
                    gapDone = true
                    let skip = plan.gapSeconds
                    let moved = min(remaining, v * skip)
                    let n = Geo.destination(lat: pos.0, lon: pos.1, bearing: course, distance: moved)
                    pos = (n.lat, n.lon)
                    remaining -= moved
                    travelled += moved
                    t += skip
                }
                emit(course: course)
            }
            if leg.stopAfter > 0 {
                v = 0
                for _ in 0..<Int(leg.stopAfter) {
                    t += 1
                    emit(course: course)
                }
            }
        }
        return out
    }
}
#endif
