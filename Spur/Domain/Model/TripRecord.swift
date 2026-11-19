import Foundation

/// Device and session context captured at trip start and end (SPEC section 5).
nonisolated struct TripContext: Codable, Sendable, Equatable, Hashable {
    enum Authorization: String, Codable, Sendable { case always, whenInUse, other }
    enum AccuracyAuthorization: String, Codable, Sendable { case full, reduced }

    var driverName: String?
    var vehicleName: String?
    var deviceModel: String?
    var systemVersion: String?
    var appVersion: String?
    var appBuild: String?
    var timeZoneIdentifier: String?
    var batteryLevelStart: Double?
    var batteryLevelEnd: Double?
    var lowPowerModeStart: Bool?
    var lowPowerModeEnd: Bool?
    var authorization: Authorization?
    var accuracyAuthorization: AccuracyAuthorization?
    /// `ProcessInfo.thermalState` at start and end (version 1.2): nominal, fair, serious, critical.
    var thermalStateStart: String?
    var thermalStateEnd: String?
}

/// The content of `trip.json`: metadata plus cached statistics.
nonisolated struct TripRecord: Codable, Sendable, Equatable, Identifiable {
    static let currentSchema = 1

    var schema: Int = TripRecord.currentSchema
    var id: UUID
    /// User title after a rename; nil means "derive from places or date".
    var customTitle: String?
    var note: String?
    var startedAt: Date
    var endedAt: Date?
    var isRecording: Bool
    /// Gaps recorded live, with their reasons.
    var gaps: [Gap] = []
    var places: [PlaceSample] = []
    var context: TripContext = TripContext()
    /// Cached statistics, written when the trip stops (and refreshed on edits).
    var statistics: TripStatistics?
    /// Settings used for the cached statistics.
    var usableAccuracyLimit: Double?
    /// True for synthetic demo trips (debug seed), never for recorded data.
    var isDemo: Bool?
    /// Decimated overview line per segment for maps and thumbnails (display cache, not raw data).
    var preview: [[LatLon]]?
    /// Road statistics from OpenStreetMap (version 1.1, SPEC 14.5); nil until analyzed.
    var roads: RoadStatistics?
    /// Motion sensor summary (version 1.2, SPEC 16.3); nil without motion data or until analyzed.
    var motion: MotionSummary?
    /// The motion recorder's problems during the trip (restarts, failed writes), nil when none.
    var motionHealth: MotionHealth?
    /// How motion recording stood when the trip started (version 1.3, SPEC 17.5), so the details
    /// can say why a trip has no sensor data; nil for older trips.
    var motionStart: MotionStart?
    /// Moving time per speed-limit sign state (SPEC 17.9): "shown" or a
    /// `SpeedLimitSelector.Hidden` raw value, seconds. Version 1.3; nil before.
    var speedLimitSeconds: [String: Double]?
    /// Pauses (SPEC 18.9), oldest first; nil before 1.4.
    var pauses: [TripPause]?

    nonisolated enum MotionStart: String, Codable, Sendable {
        /// Recording into `motion.bin`.
        case recording
        /// The setting was off.
        case off
        /// The device delivers no motion.
        case unavailable
        /// The file could not be opened.
        case failed
    }

    init(id: UUID = UUID(), startedAt: Date, isRecording: Bool = true) {
        self.id = id
        self.startedAt = startedAt
        self.isRecording = isRecording
    }

    /// Start to end place when known, otherwise nil.
    var placeTitle: String? {
        let start = statistics?.places.startPlace ?? places.first?.locality
        let end = statistics?.places.endPlace ?? places.last(where: { $0.kind == .end })?.locality
        switch (start, end) {
        case let (s?, e?) where s != e: return "\(s) nach \(e)"
        case let (s?, _): return s
        case let (nil, e?): return e
        default: return nil
        }
    }
}
