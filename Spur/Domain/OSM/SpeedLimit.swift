import Foundation

/// A tagged OSM speed limit as a sign shows it: the number in the tag's own unit (SPEC 16.2).
nonisolated struct SpeedLimit: Equatable, Hashable, Sendable {
    enum Unit: String, Sendable {
        case mph
        case kmh
    }

    var value: Int
    var unit: Unit

    var metersPerSecond: Double { unit == .mph ? Double(value) * 0.44704 : Double(value) / 3.6 }
    var unitLabel: String { unit == .mph ? "mph" : "km/h" }

    /// Only a single plain value: "35 mph", "50", "50 km/h". Lists, knots, "none", "signals" and
    /// anything else give nil: no defaults, no guessing. A value without a unit is km/h by OSM's
    /// rule, except where `unitless` is nil: in the US a bare "45" is a common mapping slip for
    /// 45 mph, so it is unknown there.
    static func parse(_ tag: String?, unitless: Unit? = .kmh) -> SpeedLimit? {
        guard let raw = tag?.trimmingCharacters(in: .whitespaces), !raw.isEmpty, !raw.contains(";") else { return nil }
        let parts = raw.split(separator: " ", omittingEmptySubsequences: true)
        guard let first = parts.first, let n = Int(first), n > 0, n < 200 else { return nil }
        switch parts.count {
        case 1: return unitless.map { SpeedLimit(value: n, unit: $0) }
        case 2 where parts[1] == "mph": return SpeedLimit(value: n, unit: .mph)
        case 2 where ["km/h", "kmh", "kph"].contains(String(parts[1])): return SpeedLimit(value: n, unit: .kmh)
        default: return nil
        }
    }

    /// The unit of a bare number at a position: km/h, or nil in the United States (contiguous
    /// states, Alaska, Hawaii; boxes, generous at the borders).
    static func unitless(atLat lat: Double, lon: Double) -> Unit? {
        let us = (24.3...49.5).contains(lat) && (-125.0...(-66.8)).contains(lon)
            || (51.0...71.6).contains(lat) && (-180.0...(-129.9)).contains(lon)
            || (18.8...22.4).contains(lat) && (-160.4...(-154.7)).contains(lon)
        return us ? nil : .kmh
    }

    /// Meters per second shown as a number in this sign's unit, rounded.
    func amount(_ metersPerSecond: Double) -> Int {
        Int((unit == .mph ? metersPerSecond / 0.44704 : metersPerSecond * 3.6).rounded())
    }
}

/// Decides, fix by fix, whether the limit of the matched way may be shown (SPEC 16.2). A wrong
/// limit is worse than none, so every rule must hold:
/// - the match stayed on the same way, in the same direction, for at least 3 consecutive fixes
///   and 30 m driven (meters count only while moving, so GPS jitter at a red light is no driving);
/// - horizontal accuracy at most 15 m, and the fix at most max(15 m, accuracy) from the way;
/// - speed at least 2 m/s, or the car stands on the way it was stably matched to;
/// - the way's limit is plain: no `maxspeed:forward`, `:backward`, `:conditional` and the like;
/// - no other candidate way about as close (within 15 m of the match's distance, legal and,
///   while moving, with a compatible bearing) carries a different limit (an untagged one counts
///   as different), so parallel frontage and freeway lanes hide the sign instead of flickering.
nonisolated struct SpeedLimitSelector {
    static let minFixes = 3
    static let minMeters = 30.0
    static let maxAccuracy = 15.0
    static let minSpeed = 2.0
    static let rivalMarginM = 15.0

    /// One other candidate way at this fix.
    struct Rival: Sendable {
        var way: Int64
        var limit: SpeedLimit?
        var distance: Double
    }

    private var way: Int64?
    private var direction: TravelDirection?
    private var count = 0
    private var meters = 0.0
    private var lastPoint: LatLon?
    private var stableWay: Int64?
    private(set) var shown: SpeedLimit?
    /// Why no sign is shown (SPEC 17.9), nil while one is.
    private(set) var hidden: Hidden? = .unstable

    nonisolated enum Hidden: String, Codable, Sendable, CaseIterable {
        /// The matched way carries no `maxspeed`.
        case noTag
        /// No match yet, or not yet stable (3 fixes and 30 m on one way and direction).
        case unstable
        /// Accuracy worse than 15 m, or the fix too far from the way.
        case inaccurate
        /// A parallel way nearby has a different limit.
        case contested
        /// The limit depends on time, lane or vehicle.
        case qualified
        /// No road tiles at the position.
        case noRoadData
    }

    mutating func reset() { self = SpeedLimitSelector() }

    /// One fix: the way it is matched to (nil when not) and the direction on it, that way's limit
    /// (nil when untagged) and whether it is qualified, the fix's distance to it, and the other
    /// candidate ways nearby.
    @discardableResult
    mutating func update(point: LatLon, accuracy: Double?, speed: Double?, matchedWay: Int64?, direction: TravelDirection = .forward,
                         limit: SpeedLimit?, qualified: Bool = false, distance: Double, rivals: [Rival]) -> SpeedLimit? {
        guard let matchedWay else {
            reset()
            hidden = .unstable
            return nil
        }
        let moving = (speed ?? 0) >= Self.minSpeed
        if matchedWay == way && direction == self.direction {
            count += 1
            if moving, let last = lastPoint { meters += OSMGeo.haversine(last, point) }
        } else {
            // Another way, or a U-turn on the same one: stability starts over.
            way = matchedWay
            self.direction = direction
            count = 1
            meters = 0
            stableWay = nil
        }
        lastPoint = point
        let stable = count >= Self.minFixes && meters >= Self.minMeters
        if stable { stableWay = matchedWay }
        let accurate = (accuracy ?? .infinity) <= Self.maxAccuracy
        let onTheWay = distance <= max(Self.maxAccuracy, accuracy ?? 0)
        let standingOnStable = !moving && stableWay == matchedWay
        let contested = rivals.contains { $0.way != matchedWay && $0.limit != limit && $0.distance <= distance + Self.rivalMarginM }
        let allowed = (stable || standingOnStable) && accurate && onTheWay && (moving || standingOnStable) && !contested && !qualified
        shown = allowed ? limit : nil
        if !(stable || standingOnStable) || !(moving || standingOnStable) {
            hidden = .unstable
        } else if !accurate || !onTheWay {
            hidden = .inaccurate
        } else if contested {
            hidden = .contested
        } else if qualified {
            hidden = .qualified
        } else if limit == nil {
            hidden = .noTag
        } else {
            hidden = nil
        }
        return shown
    }
}

/// Over the limit with hysteresis (SPEC 16.2): on when the speed is more than 5 mph (8 km/h)
/// above the limit for at least 2 s, off when it is at most 3 mph (5 km/h) above for at least
/// 2 s. Only fixes whose speed accuracy is at most 2 m/s count; others leave the state alone. A
/// gap of more than 3 s between counted fixes restarts the 2 s; more than 5 s without one
/// clears the state.
nonisolated struct OverLimitDetector {
    static let holdSeconds = 2.0
    static let maxSpeedAccuracy = 2.0
    static let maxGapSeconds = 3.0
    static let timeoutSeconds = 5.0

    static func onMargin(_ unit: SpeedLimit.Unit) -> Double { unit == .mph ? 5 * 0.44704 : 8 / 3.6 }
    static func offMargin(_ unit: SpeedLimit.Unit) -> Double { unit == .mph ? 3 * 0.44704 : 5 / 3.6 }

    private(set) var over = false
    /// How far above the limit, in the sign's unit, while `over`.
    private(set) var excess: Int?
    private var since: Double?
    private var limit: SpeedLimit?
    private var lastValid: Double?

    @discardableResult
    mutating func update(time: Double, speed: Double?, speedAccuracy: Double?, limit: SpeedLimit?) -> Bool {
        if limit != self.limit {
            self.limit = limit
            over = false
            excess = nil
            since = nil
        }
        guard let limit else { return false }
        guard let speed, let acc = speedAccuracy, acc >= 0, acc <= Self.maxSpeedAccuracy else {
            since = nil
            if over, let last = lastValid, time - last > Self.timeoutSeconds {
                over = false
                excess = nil
            }
            return over
        }
        if let last = lastValid, time - last > Self.maxGapSeconds {
            since = nil
            if over && time - last > Self.timeoutSeconds {
                over = false
                excess = nil
            }
        }
        lastValid = time
        let changing = over ? speed <= limit.metersPerSecond + Self.offMargin(limit.unit)
                            : speed > limit.metersPerSecond + Self.onMargin(limit.unit)
        if changing {
            let start = since ?? time
            since = start
            if time - start >= Self.holdSeconds {
                over.toggle()
                since = nil
            }
        } else {
            since = nil
        }
        // Still red in the hysteresis band but not above the limit: no amount to announce.
        excess = over ? Optional(limit.amount(speed) - limit.value).flatMap { $0 > 0 ? $0 : nil } : nil
        return over
    }
}
