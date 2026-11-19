import Foundation

/// All statistics of one trip, cached in `trip.json`.
nonisolated struct TripStatistics: Codable, Sendable, Equatable {
    var distance: Double
    var time: TimeStats
    var speed: SpeedStats
    var stops: StopStats
    var roadType: RoadTypeStats
    var elevation: ElevationStats?
    var dynamics: DynamicsStats
    var dayNight: DayNightStats
    var gps: GPSQualityStats
    var places: PlacesSummary
    var segmentCount: Int
}

/// Statistics plus the per-fix data the detail map needs.
nonisolated struct TripAnalysis: Sendable {
    var statistics: TripStatistics
    var roadClassPerFix: [RoadClass?]
    var gaps: [Gap]
    var stops: [StopStats.Stop]
    var track: Track
}

nonisolated enum TripAnalyzer {
    static func analyze(
        fixes: [Fix], recordedGaps: [Gap] = [], places: [PlaceSample] = [], config: StatsConfig = .default,
        pauses: [TripPause] = []
    ) -> TripAnalysis {
        let track = Track(fixes: fixes, config: config)
        let gaps = track.gaps(recorded: recordedGaps)
        let time = TimeStats.compute(track, pauses: pauses)
        let stops = StopStats.stops(track)
        let classes = RoadTypeClassifier.classify(track, stops: stops)
        let stats = TripStatistics(
            distance: track.totalDistance,
            time: time,
            speed: SpeedStats.compute(track, time: time),
            stops: StopStats.compute(track, stops: stops),
            roadType: RoadTypeClassifier.stats(track, classes: classes),
            elevation: ElevationStats.compute(fixes),
            dynamics: DynamicsStats.compute(track),
            dayNight: DayNightStats.compute(track),
            gps: GPSQualityStats.compute(track, gaps: gaps),
            places: PlacesSummary.compute(samples: places, track: track),
            segmentCount: track.segments.count
        )
        return TripAnalysis(statistics: stats, roadClassPerFix: classes, gaps: gaps, stops: stops, track: track)
    }
}
