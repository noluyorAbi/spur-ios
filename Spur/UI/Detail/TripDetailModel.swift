import Foundation
import MapKit
import Observation
import SwiftUI

/// Loads one trip and its analysis off the main actor, and prepares display series.
@Observable
final class TripDetailModel {
    enum Coloring: String, CaseIterable, Identifiable {
        case speed, road
        var id: String { rawValue }
        var label: String { self == .speed ? "Geschwindigkeit" : "Streckenart" }
    }

    struct Run: Identifiable {
        var id: Int
        var coordinates: [CLLocationCoordinate2D]
        var color: Color
    }

    struct SeriesPoint: Identifiable {
        var id: Int
        var date: Date
        var value: Double
    }

    var record: TripRecord
    private(set) var fixes: [Fix] = []
    private(set) var analysis: TripAnalysis?
    private(set) var events: [TripEvent] = []
    private(set) var loaded = false
    /// `roads.json` of version 1.1: passed features and the way per fix (nil until analyzed).
    private(set) var roadDetails: RoadDetails?
    /// `motion-analysis.json` of version 1.2: events, roughness stretches, the chart series.
    private(set) var motionDetails: MotionDetails?
    /// The chart's bands, at most about 600, built off the main actor.
    private(set) var motionBands: [MotionChart.Band] = []
    /// Motion events the map shows: every event with a position, but only the strongest jolts
    /// (a rough road gives hundreds), at most `mapEventLimit` in all.
    private(set) var mapMotionEvents: [MotionEvent] = []
    nonisolated static let mapBumpLimit = 30
    nonisolated static let mapEventLimit = 150

    nonisolated static func mapEvents(_ events: [MotionEvent]) -> [MotionEvent] {
        let located = events.filter { $0.latitude != nil && $0.longitude != nil }
        let bumps = located.filter { $0.kind == .bump }.sorted { $0.peak > $1.peak }.prefix(mapBumpLimit)
        let others = located.filter { $0.kind != .bump }.sorted { abs($0.peak) > abs($1.peak) }
        return Array((others + bumps).prefix(mapEventLimit)).sorted { $0.peakTime < $1.peakTime }
    }
    /// Passed features the map shows (signals once per site and crossing, stop signs, skewed junctions).
    var mapFeatures: [PassedFeature] {
        var out: [PassedFeature] = []
        var lastSite: Int64?
        for f in roadDetails?.passed ?? [] where f.poiKind != nil {
            if f.type == .trafficSignals {
                if f.siteId == lastSite { continue }
                lastSite = f.siteId
            }
            out.append(f)
        }
        return out
    }
    private(set) var speedRuns: [Run] = []
    private(set) var roadRuns: [Run] = []
    private(set) var speedSeries: [SeriesPoint] = []
    /// Moving time per 10 unit speed class, in the chosen unit (km/h or mph).
    private(set) var histogram: [HistogramBin] = []

    struct HistogramBin: Identifiable {
        var id: Int
        /// Lower bound in the display unit.
        var lower: Double
        var seconds: Double
    }
    private(set) var elevationSeries: [SeriesPoint] = []
    private(set) var bounds: MKCoordinateRegion?
    /// Thin dashed connectors across gaps and jumps, so a missing stretch never looks like road.
    private(set) var gapLines: [[CLLocationCoordinate2D]] = []
    /// The two fixes around each gap and jump, for the gap fill (SPEC 18.8).
    private(set) var gapEnds: [(a: Fix, b: Fix)] = []
    @ObservationIgnored private var runOf: [Int] = []

    init(record: TripRecord) {
        self.record = record
    }

    /// Speed color scale: one hue (the accent), so it reads for color-blind users. On dark faster
    /// is lighter; on the light map faster is deeper, every step at least 3:1 (SPEC 18.1).
    static let speedSteps: [(upToKmh: Double, color: Color)] = [
        (30, step(0x3F7FD8, 0.20, 0.30, 0.48)),
        (50, step(0x2F6AC4, 0.24, 0.42, 0.70)),
        (70, step(0x2457A8, 0.30, 0.56, 0.88)),
        (90, step(0x1B4589, 0.48, 0.70, 0.98)),
        (110, step(0x13336A, 0.70, 0.83, 1.00)),
        (.infinity, step(0x0B2149, 0.92, 0.96, 1.00)),
    ]

    private static func step(_ light: UInt32, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Color {
        Theme.adaptive(light: Theme.rgb(light), dark: UIColor(red: r, green: g, blue: b, alpha: 1))
    }

    /// Legend labels of the speed steps (defined in km/h) in the chosen unit, for example
    /// `<30, 30, 50, 70, 90, 110+` or `<19, 19, 31, 43, 56, 68+`.
    static func legendLabels(_ units: UnitSystem) -> [String] {
        func shown(_ kmh: Double) -> String { "\(Int(units.speed(kmh / 3.6).rounded()))" }
        return speedSteps.indices.map { k in
            if k == 0 { return "<" + shown(speedSteps[0].upToKmh) }
            return shown(speedSteps[k - 1].upToKmh) + (speedSteps[k].upToKmh.isFinite ? "" : "+")
        }
    }

    static func speedStep(_ mps: Double?) -> Int {
        guard let mps else { return 0 }
        let kmh = mps * 3.6
        return speedSteps.firstIndex(where: { kmh < $0.upToKmh }) ?? speedSteps.count - 1
    }

    func load(store: TripStore, config: StatsConfig, units: UnitSystem) async {
        let id = record.id
        let record = self.record
        let result = await Task.detached(priority: .userInitiated) { () -> (FixFile.Contents, [TripEvent], TripAnalysis) in
            let contents = store.loadFixes(id)
            let events = store.loadEvents(id)
            var gaps = record.gaps
            for g in contents.gaps where !gaps.contains(g) { gaps.append(g) }
            let effective = StatsConfig(usableAccuracy: record.usableAccuracyLimit ?? config.usableAccuracy)
            let analysis = TripAnalyzer.analyze(fixes: contents.fixes, recordedGaps: gaps, places: record.places, config: effective, pauses: record.pauses ?? [])
            return (contents, events, analysis)
        }.value
        fixes = result.0.fixes
        events = result.1
        analysis = result.2
        buildDisplay(units: units)
        buildGapMarkers()
        loaded = true
        await loadRoads(store: store)
    }

    /// The running trip (SPEC 17.2, 17.8): the engine's fixes, events and gaps so far, through
    /// the same analysis as `load`, off the main actor. The caller throttles it (at most every 5 s).
    func refreshLive(fixes: [Fix], events: [TripEvent], record: TripRecord, config: StatsConfig, units: UnitSystem) async {
        let effective = StatsConfig(usableAccuracy: record.usableAccuracyLimit ?? config.usableAccuracy)
        let analysis = await Task.detached(priority: .utility) {
            TripAnalyzer.analyze(fixes: fixes, recordedGaps: record.gaps, places: record.places, config: effective, pauses: record.pauses ?? [])
        }.value
        self.record = record
        self.fixes = fixes
        self.events = events
        self.analysis = analysis
        buildDisplay(units: units)
        buildGapMarkers()
        loaded = true
    }

    /// Reads `roads.json` and `motion-analysis.json` off the main actor (after an analysis they change).
    func loadRoads(store: TripStore) async {
        let id = record.id
        let (roads, motion) = await Task.detached(priority: .userInitiated) { (store.loadRoadDetails(id), store.loadMotionDetails(id)) }.value
        roadDetails = roads
        motionDetails = motion
        let (bands, events) = await Task.detached(priority: .userInitiated) {
            (motion.map { MotionChart.bands($0) } ?? [], Self.mapEvents(motion?.events ?? []))
        }.value
        motionBands = bands
        mapMotionEvents = events
    }

    private func buildDisplay(units: UnitSystem) {
        guard let analysis else { return }
        let track = analysis.track
        let n = fixes.count
        guard n > 0 else { return }
        // Display indices: usable fixes in display runs (split at gaps and jumps), thinned to
        // about 2500 vertices. Raw data stays untouched.
        let usable = (0..<n).filter { track.isUsable($0) }
        let displayRuns = TrailGeometry.displayRuns(fixes, config: track.config)
        var runOf = [Int](repeating: -1, count: n)
        for (k, run) in displayRuns.enumerated() { for i in run { runOf[i] = k } }
        self.runOf = runOf
        let step = max(1, displayRuns.reduce(0) { $0 + $1.count } / 2500)
        var shown: [Int] = []
        for run in displayRuns {
            shown.append(contentsOf: Swift.stride(from: 0, to: run.count, by: step).map { run[$0] })
            if let last = run.last, shown.last != last { shown.append(last) }
        }
        gapLines = zip(displayRuns, displayRuns.dropFirst()).map { a, b in
            [fixes[a.last!].coordinate, fixes[b.first!].coordinate]
        }
        gapEnds = zip(displayRuns, displayRuns.dropFirst()).map { a, b in (fixes[a.last!], fixes[b.first!]) }

        speedRuns = runs(shown, track: track) { Self.speedStep(self.fixes[$0].speed ?? track.intervalSpeed[$0]) }
            colorFor: { Self.speedSteps[$0].color }
        let classes = analysis.roadClassPerFix
        roadRuns = runs(shown, track: track) { classes[$0].map { RoadClass.allCases.firstIndex(of: $0)! } ?? -1 }
            colorFor: { $0 < 0 ? Theme.Text.ink(0.4) : RoadClass.allCases[$0].color }

        histogram = SpeedStats.histogram(track, unitsPerMps: units.unitsPerMps, binWidth: 10).map {
            HistogramBin(id: $0.index, lower: Double($0.index) * 10, seconds: $0.seconds)
        }
        let seriesStep = max(1, n / 600)
        speedSeries = Swift.stride(from: 0, to: n, by: seriesStep).compactMap { i in
            guard let v = fixes[i].speed ?? track.intervalSpeed[i] else { return nil }
            return SeriesPoint(id: i, date: fixes[i].date, value: units.speed(v))
        }
        elevationSeries = Swift.stride(from: 0, to: n, by: seriesStep).compactMap { i in
            guard let a = fixes[i].altitude else { return nil }
            return SeriesPoint(id: i, date: fixes[i].date, value: units.elevation(a))
        }

        // Frame what is drawn: a jump outlier that is never drawn must not zoom the map out.
        let drawn = displayRuns.flatMap { $0 }
        let framed = drawn.isEmpty ? usable : drawn
        if !framed.isEmpty {
            var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
            for i in framed {
                minLat = min(minLat, fixes[i].latitude); maxLat = max(maxLat, fixes[i].latitude)
                minLon = min(minLon, fixes[i].longitude); maxLon = max(maxLon, fixes[i].longitude)
            }
            bounds = MKCoordinateRegion(
                center: .init(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
                span: .init(latitudeDelta: max(0.005, (maxLat - minLat) * 1.15), longitudeDelta: max(0.005, (maxLon - minLon) * 1.15))
            )
        }
    }

    /// Consecutive shown fixes with the same key form one colored run; runs share their joint
    /// point and break between display runs (gaps and jumps).
    private func runs(_ shown: [Int], track: Track, key: (Int) -> Int, colorFor: (Int) -> Color) -> [Run] {
        var out: [Run] = []
        var current: [CLLocationCoordinate2D] = []
        var currentKey: Int?
        var previous: Int?
        func flush() {
            if current.count >= 2, let k = currentKey {
                out.append(Run(id: out.count, coordinates: current, color: colorFor(k)))
            }
        }
        for i in shown {
            let c = fixes[i].coordinate
            let k = key(i)
            let newSegment = previous.map { runOf[$0] != runOf[i] } ?? false
            if newSegment {
                flush()
                current = [c]
                currentKey = k
            } else if k != currentKey {
                flush()
                current = current.last.map { [$0, c] } ?? [c]
                currentKey = k
            } else {
                current.append(c)
            }
            previous = i
        }
        flush()
        return out
    }

    /// Positions of gap starts, for markers (computed once per load).
    private(set) var gapMarkers: [GapMarker] = []

    struct GapMarker: Identifiable {
        var id: Int
        var coordinate: CLLocationCoordinate2D
        var gap: Gap
    }

    private func buildGapMarkers() {
        guard let analysis else { return }
        var markers: [GapMarker] = []
        var i = 0
        for (k, gap) in analysis.gaps.enumerated() {
            while i + 1 < fixes.count && fixes[i + 1].timestampMs <= gap.startMs { i += 1 }
            if fixes.indices.contains(i) { markers.append(GapMarker(id: k, coordinate: fixes[i].coordinate, gap: gap)) }
        }
        gapMarkers = markers
    }
}
