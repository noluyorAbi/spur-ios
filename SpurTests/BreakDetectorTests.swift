import Foundation
import Testing
@testable import Spur

/// SPEC 18.9: the automatic pause's ground truth on synthetic stops. Targets: no light and no jam
/// paused, at least 90 % of breaks of N minutes or more found, boundaries within 30 s.
struct BreakDetectorTests {
    typealias O = BreakDetector.Observation

    enum Kind { case light, jam, carPark, kerb }

    struct Stop {
        var kind: Kind
        var seconds: Double
        var start: Double = 0
        var resume: Double = 0
    }

    /// A drive at 1 Hz: 60 s driving, then the stop, then 120 s driving, per stop in turn. `seed`
    /// varies the noise (GPS speed at a standstill up to 0.6 m/s). The place of a stop arrives a
    /// few seconds after it began, as the road lookup does.
    static func drive(_ stops: [Stop], seed: UInt64) -> ([O], [Stop]) {
        var rng = Rng(seed)
        var out: [O] = []
        var t = 0.0
        var placed: [Stop] = []
        func driving(_ seconds: Int) {
            for _ in 0..<seconds {
                out.append(O(time: t, speed: 12 + rng.next() * 4))
                t += 1
            }
        }
        driving(60)
        for var s in stops {
            s.start = t
            let n = Int(s.seconds)
            let lookupDelay = 2 + Int(rng.next() * 5)
            for k in 0..<n {
                var o = O(time: t, speed: rng.next() * 0.6)
                let place: BreakDetector.Place
                switch s.kind {
                case .light:
                    place = rng.next() < 0.5 ? .majorRoad : .minorRoad
                case .jam:
                    // Stop and go on a motorway: a few seconds of creeping every minute or so.
                    if k % 70 > 62 { o.speed = 2 + rng.next() * 2 }
                    place = .majorRoad
                case .carPark:
                    // Out of the car after 60 s and walking away with the phone for a while.
                    if k >= 60 && k < 240 { o.speed = 1.2 + rng.next() * 1.1 }
                    place = .offRoad
                case .kerb:
                    place = .minorRoad
                }
                if k >= lookupDelay { o.place = place }
                out.append(o)
                t += 1
            }
            s.resume = t
            placed.append(s)
            driving(120)
        }
        return (out, placed)
    }

    struct Rng {
        var state: UInt64
        init(_ seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    static func stops() -> [Stop] {
        var s: [Stop] = []
        for sec in stride(from: 30.0, through: 150, by: 15) { s.append(Stop(kind: .light, seconds: sec)) }    // 9 lights
        for min in [3.0, 5, 7, 9, 11, 13, 15] { s.append(Stop(kind: .jam, seconds: min * 60)) }               // 7 jams
        for min in [4.0, 5, 6, 8, 10, 12, 15, 18, 20, 25, 28, 30] { s.append(Stop(kind: .carPark, seconds: min * 60)) } // 12 breaks
        for min in [4.0, 6, 11, 16, 30] { s.append(Stop(kind: .kerb, seconds: min * 60)) }                      // 5 kerbside
        return s
    }

    @Test(arguments: [3.0, 5.0, 10.0])
    func lightsAndJamsNeverPauseAndBreaksAreFound(_ minutes: Double) {
        var lightsPaused = 0, jamsPaused = 0, found = 0, expected = 0, worstStart = 0.0, worstEnd = 0.0
        for seed in UInt64(1)...3 {
            let (obs, placed) = Self.drive(Self.stops(), seed: seed)
            var d = BreakDetector(config: .init(minutes: minutes))
            var events: [BreakDetector.Event] = []
            for o in obs { if let e = d.observe(o) { events.append(e) } }
            var starts: [Double] = [], ends: [Double] = []
            for e in events {
                switch e {
                case .pauseStarted(let at, _): starts.append(at)
                case .pauseEnded(let at): ends.append(at)
                case .pauseSpan(let from, let to, _):
                    starts.append(from)
                    ends.append(to)
                }
            }
            for s in placed {
                let hit = starts.firstIndex { $0 >= s.start - 30 && $0 <= s.resume }
                switch s.kind {
                case .light: if hit != nil { lightsPaused += 1 }
                case .jam: if hit != nil { jamsPaused += 1 }
                case .carPark, .kerb:
                    guard s.seconds >= minutes * 60 else { continue }
                    expected += 1
                    if let k = hit {
                        found += 1
                        worstStart = max(worstStart, abs(starts[k] - s.start))
                        if let end = ends.first(where: { $0 >= starts[k] }) { worstEnd = max(worstEnd, abs(end - s.resume)) }
                    }
                }
            }
        }
        print("PAUSE N=\(Int(minutes)) min: lights paused \(lightsPaused), jams paused \(jamsPaused), breaks found \(found) of \(expected), worst start \(Int(worstStart)) s, worst end \(Int(worstEnd)) s")
        #expect(lightsPaused == 0 && jamsPaused == 0)
        #expect(Double(found) >= 0.9 * Double(expected))
        #expect(worstStart <= 30 && worstEnd <= 30)
    }

    @Test func aLongStopOnAMajorRoadIsNeverABreakAndWithoutRoadDataItIs() {
        var jam = BreakDetector(config: .init(minutes: 3))
        var paused = false
        for t in 0..<1800 {
            if case .pauseStarted = jam.observe(O(time: Double(t), speed: 0.2, place: .majorRoad)) { paused = true }
        }
        #expect(!paused, "a jam on a major road, however long")
        var unknown = BreakDetector(config: .init(minutes: 3))
        var evidence: String?
        for t in 0..<400 {
            if case .pauseStarted(_, let e) = unknown.observe(O(time: Double(t), speed: 0.2)) { evidence = e }
        }
        #expect(evidence == "langer Halt, keine Straßendaten")
    }

    /// The place of a car from the road segments around it.
    @Test func placeFromTheRoadsAround() {
        func seg(_ id: Int64, _ tags: [String: String], lat: Double) -> RoadSegment {
            let a = LatLon(lat: lat, lon: -96.80), b = LatLon(lat: lat, lon: -96.79)
            let len = OSMGeo.haversine(a, b)
            return RoadSegment(id: "\(id)", wayId: id, fromNode: id * 10, toNode: id * 10 + 1, nodeIds: [id * 10, id * 10 + 1],
                               coords: [a, b], cum: [0, len], length: len, tags: tags, categories: [.local], directions: [.forward, .backward])
        }
        let roads = [seg(1, ["highway": "primary"], lat: 32.780), seg(2, ["highway": "residential"], lat: 32.782),
                     seg(3, ["highway": "service", "service": "parking_aisle"], lat: 32.784)]
        #expect(BreakDetector.place(LatLon(lat: 32.78005, lon: -96.795), segments: roads) == .majorRoad, "5 m from a primary")
        // A forecourt beside the primary: 20 m from its centre line, outside its four lanes.
        #expect(BreakDetector.place(LatLon(lat: 32.78018, lon: -96.795), segments: roads) == .offRoad, "a station beside a primary")
        var wide = roads[0]
        wide.tags["lanes"] = "8"
        #expect(BreakDetector.place(LatLon(lat: 32.78018, lon: -96.795), segments: [wide]) == .majorRoad, "inside eight lanes")
        #expect(BreakDetector.place(LatLon(lat: 32.78210, lon: -96.795), segments: roads) == .minorRoad, "11 m from a residential")
        #expect(BreakDetector.place(LatLon(lat: 32.78400, lon: -96.795), segments: roads) == .offRoad, "a parking aisle is a car park")
        #expect(BreakDetector.place(LatLon(lat: 32.7860, lon: -96.795), segments: roads) == .offRoad, "far from every road")
        #expect(BreakDetector.place(LatLon(lat: 32.78, lon: -96.795), segments: []) == .unknown)
        // Owner's trips: a service road 1.5 m away beside a major road within its reach is a car
        // park; a residential 9 m and a secondary 10 m away is the junction, the major road.
        let lot = [seg(4, ["highway": "primary"], lat: 32.7900), seg(5, ["highway": "service"], lat: 32.79012)]
        #expect(BreakDetector.place(LatLon(lat: 32.790135, lon: -96.795), segments: lot) == .minorRoad, "the lot's service road is clearly closer")
        let junction = [seg(6, ["highway": "secondary"], lat: 32.79001), seg(7, ["highway": "residential"], lat: 32.790181)]
        #expect(BreakDetector.place(LatLon(lat: 32.79010, lon: -96.795), segments: junction) == .majorRoad, "only 1 m closer: the major road")
    }
}
