import Foundation

/// Tells a real break from a traffic stop, fix by fix, from the location alone (SPEC 18.9; the
/// owner, 2026-11-17: the pause is based on the location only). Pure.
///
/// A break is a stop of at least `minutes` at a place that is not traffic: off every road (a car
/// park, a station forecourt, a parking aisle) or on a minor road (parked at the kerb). On a major
/// road (motorway, trunk, primary, secondary and their links) a stop is a jam or a long light and
/// never a break, however long. Without road data around the car a long stop counts as a break.
/// A break is reported retroactively from the stop's start; it ends when the car drives again (at
/// least `resumeSpeed` for `resumeSeconds`), from the movement's start.
nonisolated struct BreakDetector {
    struct Config: Sendable {
        var minutes = 5.0
        /// Below this a car stands (GPS speed noise at a standstill stays under it).
        var stopSpeed = 1.5
        /// A stop goes on below this: someone walking away from the car with the phone.
        var walkSpeed = 2.5
        var resumeSpeed = 3.0
        var resumeSeconds = 10.0
    }

    /// Where a stopped car stands, from the road data around it.
    enum Place: String, Sendable, Equatable {
        case offRoad, minorRoad, majorRoad, unknown
    }

    struct Observation: Sendable {
        var time: Double
        var speed: Double?
        /// Where the car of this stop stands, once looked up; nil until then.
        var place: Place? = nil
    }

    enum Event: Sendable, Equatable {
        case pauseStarted(at: Double, evidence: String)
        case pauseEnded(at: Double)
        /// A stop that reached the break length only as the car left (a break of exactly N
        /// minutes): the whole span, after the fact.
        case pauseSpan(from: Double, to: Double, evidence: String)
    }

    var config = Config()
    private(set) var paused = false
    /// The start of the stop in progress, nil while driving; a new value means a new stop.
    private(set) var stopStart: Double?
    private var place: Place?
    private var movingSince: Double?

    init(config: Config = Config()) {
        self.config = config
    }

    /// A trip relaunched during an automatic pause: the detector waits for the resume.
    mutating func resumeAsPaused() {
        paused = true
        movingSince = nil
    }

    mutating func observe(_ o: Observation) -> Event? {
        let speed = o.speed ?? 0
        if paused {
            if speed >= config.resumeSpeed {
                let since = movingSince ?? o.time
                movingSince = since
                if o.time - since >= config.resumeSeconds {
                    paused = false
                    movingSince = nil
                    stopStart = nil
                    place = nil
                    return .pauseEnded(at: since)
                }
            } else {
                movingSince = nil
            }
            return nil
        }
        let limit = stopStart == nil ? config.stopSpeed : config.walkSpeed
        guard speed < limit else {
            defer {
                stopStart = nil
                place = nil
            }
            if let start = stopStart, o.time - start >= config.minutes * 60, let evidence = Self.evidence(place) {
                return .pauseSpan(from: start, to: o.time, evidence: evidence)
            }
            return nil
        }
        if stopStart == nil { stopStart = o.time }
        if let p = o.place { place = p }
        guard let start = stopStart, o.time - start >= config.minutes * 60, let evidence = Self.evidence(place) else { return nil }
        paused = true
        movingSince = nil
        return .pauseStarted(at: start, evidence: evidence)
    }

    /// What the place says about a long stop, nil when it is traffic. A stop whose place is not
    /// known yet counts like one without road data.
    static func evidence(_ place: Place?) -> String? {
        switch place ?? .unknown {
        case .offRoad: return "abseits der Straße"
        case .minorRoad: return "geparkt an einer Nebenstraße"
        case .majorRoad: return nil
        case .unknown: return "langer Halt, keine Straßendaten"
        }
    }

    /// Classes where a long stop is a jam or a long light, never a break.
    static let majorClasses: Set<String> = ["motorway", "motorway_link", "trunk", "trunk_link", "primary", "primary_link",
                                            "secondary", "secondary_link"]
    /// Ways a car parks on, counted as off the road.
    static let parkingServices: Set<String> = ["parking_aisle", "driveway", "drive-through", "parking"]
    /// Farther than this from every minor road, a car stands off the road (a parked car's offset
    /// from the centre line plus GPS error).
    static let roadReachM = 25.0
    /// GPS error added to a major road's half width.
    static let gpsAllowanceM = 8.0
    /// A minor road at least this much closer than a major road decides the place.
    static let minorCloserM = 5.0

    /// How far from its centre line a car can stand on this way while in a lane: half the lanes
    /// (from `lanes`, else typical for the class) at 3.5 m, plus GPS error. Beside it, on a forecourt
    /// or in a lot, the car is off the road.
    static func reach(_ s: RoadSegment) -> Double {
        let highway = s.tags["highway"] ?? ""
        guard majorClasses.contains(highway) else { return roadReachM }
        let typical: Double = highway.hasSuffix("_link") ? 1 : highway == "motorway" ? 6 : highway == "secondary" ? 2 : 4
        let lanes = s.tags["lanes"].flatMap(Double.init) ?? (s.directions.count == 1 ? max(1, typical / 2) : typical)
        return lanes * 3.5 / 2 + gpsAllowanceM
    }

    /// Where a car at `p` stands, from the road segments around it: in a major road's lanes, near
    /// a minor road, or off every road.
    static func place(_ p: LatLon, segments: [RoadSegment]) -> Place {
        guard !segments.isEmpty else { return .unknown }
        let degLat = 1000.0 / 110_540, degLon = 1000.0 / max(1, 111_320 * cos(p.lat * .pi / 180))
        var major: Double?, minor: Double?
        for s in segments where s.coords.count >= 2 {
            let highway = s.tags["highway"] ?? ""
            if highway == "service", let kind = s.tags["service"], parkingServices.contains(kind) { continue }
            if ["footway", "path", "cycleway", "pedestrian", "steps", "track"].contains(highway) { continue }
            // Cheap reject: no vertex within about 1 km (segments are short).
            guard s.coords.contains(where: { abs($0.lat - p.lat) < degLat && abs($0.lon - p.lon) < degLon }) else { continue }
            let d = OSMGeo.project(p, onto: s.coords).distance
            if majorClasses.contains(highway) {
                if d <= reach(s) { major = min(major ?? .infinity, d) }
            } else if d <= roadReachM {
                minor = min(minor ?? .infinity, d)
            }
        }
        // In a major road's lanes, unless a minor road or a car park's service road is clearly
        // closer: a car parked beside a major road (owner's trips, 2026-11-18: a service road at
        // 1.5 m, the major road within its lane reach).
        if let m = major, minor.map({ $0 > m - minorCloserM }) ?? true { return .majorRoad }
        return minor != nil ? .minorRoad : .offRoad
    }
}
