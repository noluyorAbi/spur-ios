import Foundation
import Testing
@testable import Spur

/// One parent case exported by `tools/oracle/export.ts` (SPEC 14.4).
nonisolated struct OracleCase: @unchecked Sendable {
    struct Drive {
        var label: String
        var fixes: [MatchFix]
        var passes: [Int64]
        var passTimes: [Double?]
    }

    var caseNo: Int
    var fixture: String
    var root: [String: Any]
    var elements: OSMElements
    var drives: [Drive]

    var features: [[String: Any]] { root["features"] as? [[String: Any]] ?? [] }

    static let cache = OracleCache()

    static func load(_ n: Int) throws -> OracleCase {
        if let hit = cache.get(n) { return hit }
        let root = try #require(try JSONSerialization.jsonObject(with: TestResources.data("oracle-case\(n)")) as? [String: Any])
        let fixture = try #require(root["fixture"] as? String)
        let elements = try OverpassParser.parse(TestResources.data(fixture))
        var drives: [Drive] = []
        for d in root["drives"] as? [[String: Any]] ?? [] {
            let fixes = (d["fixes"] as? [[String: Any]] ?? []).map { f in
                MatchFix(time: (f["t"] as! NSNumber).doubleValue / 1000, lat: (f["lat"] as! NSNumber).doubleValue,
                         lon: (f["lon"] as! NSNumber).doubleValue, accuracy: (f["accuracy"] as? NSNumber)?.doubleValue,
                         speed: (f["speed"] as? NSNumber)?.doubleValue, course: (f["heading"] as? NSNumber)?.doubleValue)
            }
            let passes = d["passes"] as? [[String: Any]] ?? []
            drives.append(Drive(label: d["label"] as? String ?? "", fixes: fixes,
                                passes: passes.map { ($0["nodeId"] as! NSNumber).int64Value },
                                passTimes: passes.map { ($0["t"] as? NSNumber).map { $0.doubleValue / 1000 } }))
        }
        let c = OracleCase(caseNo: n, fixture: fixture, root: root, elements: elements, drives: drives)
        cache.put(n, c)
        return c
    }
}

nonisolated final class OracleCache: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Int: OracleCase] = [:]
    private var networks: [Int: RoadNetwork] = [:]
    func get(_ n: Int) -> OracleCase? { lock.withLock { items[n] } }
    func put(_ n: Int, _ c: OracleCase) { lock.withLock { items[n] = c } }
    func network(_ n: Int, _ build: () -> RoadNetwork) -> RoadNetwork {
        if let hit = lock.withLock({ networks[n] }) { return hit }
        let net = build()
        lock.withLock { networks[n] = net }
        return net
    }
}

extension OracleCase {
    var network: RoadNetwork { OracleCase.cache.network(caseNo) { RoadNetwork(elements) } }
}

/// Scoring convention (phase R3): node-level feature passes, multiset per drive,
/// pooled per case.
nonisolated enum PassScore {
    struct Counts: Equatable {
        var truePositives = 0
        var predicted = 0
        var truth = 0
        var precision: Double { predicted == 0 ? 1 : Double(truePositives) / Double(predicted) }
        var recall: Double { truth == 0 ? 1 : Double(truePositives) / Double(truth) }
        static func + (a: Counts, b: Counts) -> Counts {
            Counts(truePositives: a.truePositives + b.truePositives, predicted: a.predicted + b.predicted, truth: a.truth + b.truth)
        }
    }

    static func score(predicted: [Int64], truth: [Int64]) -> Counts {
        var p: [Int64: Int] = [:]
        var t: [Int64: Int] = [:]
        for id in predicted { p[id, default: 0] += 1 }
        for id in truth { t[id, default: 0] += 1 }
        let tp = p.reduce(0) { $0 + min($1.value, t[$1.key] ?? 0) }
        return Counts(truePositives: tp, predicted: predicted.count, truth: truth.count)
    }
}

struct RoadMatchingTests {
    nonisolated static let allCases = Array(1...9)

    // MARK: Parity with the parent (SPEC 14.3)

    @Test(arguments: allCases)
    func segmentsMatchTheParent(_ n: Int) throws {
        let c = try OracleCase.load(n)
        let net = c.network
        let parent = c.root["segments"] as? [[String: Any]] ?? []
        #expect(net.segments.count == parent.count)
        for (s, p) in zip(net.segments, parent) {
            #expect(s.id == p["id"] as? String)
            #expect(abs(s.length - ((p["lengthM"] as? NSNumber)?.doubleValue ?? -1)) < 1e-9, "segment \(s.id)")
        }
    }

    /// SPEC 14.4: skew flags equal the parent's for 100 % of the junction nodes in all nine fixtures.
    @Test(arguments: allCases)
    func skewFlagsAndFeaturesMatchTheParent(_ n: Int) throws {
        let c = try OracleCase.load(n)
        let net = c.network
        var junctions = 0
        var equal = 0
        var maxAngleDiff = 0.0
        #expect(net.features.count == c.features.count)
        for f in c.features {
            let id = (f["nodeId"] as! NSNumber).int64Value
            let mine = try #require(net.features[id], "feature node \(id) missing")
            #expect(mine.type.rawValue == f["type"] as? String, "type of \(id)")
            #expect(mine.lat == (f["lat"] as! NSNumber).doubleValue && mine.lon == (f["lon"] as! NSNumber).doubleValue)
            guard let angles = f["approachAngles"] as? [NSNumber] else {
                #expect(mine.approachAngles == nil)
                continue
            }
            junctions += 1
            let theirs = angles.map(\.doubleValue)
            let ours = mine.approachAngles ?? []
            #expect(ours.count == theirs.count, "angles of \(id)")
            for (a, b) in zip(ours, theirs) { maxAngleDiff = max(maxAngleDiff, abs(a - b)) }
            if mine.skewed == (f["skewed"] as? Bool) { equal += 1 }
        }
        let share = junctions > 0 ? Double(equal) / Double(junctions) : 1
        print(String(format: "SKEW PARITY case %d %@: %d of %d junctions equal (%.1f %%), %d skewed, max angle difference %.2e deg",
                     n, c.fixture, equal, junctions, share * 100, net.features.values.filter { $0.skewed == true }.count, maxAngleDiff))
        #expect(equal == junctions, "skew parity case \(n): \(equal) of \(junctions)")
        #expect(maxAngleDiff < 1e-9)
    }

    @Test(arguments: allCases)
    func categoriesAndSpeedLimitsMatchTheParent(_ n: Int) throws {
        let c = try OracleCase.load(n)
        let categories = c.root["categories"] as? [String: [String]] ?? [:]
        let ways = Dictionary(c.elements.ways.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(!categories.isEmpty)
        for (wayId, expected) in categories {
            let way = try #require(ways[Int64(wayId)!])
            #expect(RoadRules.categories(way.tags ?? [:]).map(\.rawValue) == expected, "way \(wayId)")
        }
        for (tag, mph) in c.root["maxspeed"] as? [String: Any] ?? [:] {
            let expected = (mph as? NSNumber)?.doubleValue
            let mine = RoadRules.maxspeedMph(tag)
            if let expected { #expect(mine != nil && abs(mine! - expected) < 1e-9, "maxspeed \(tag)") } else { #expect(mine == nil, "maxspeed \(tag)") }
        }
    }

    // MARK: Acceptance (SPEC 14.4)

    enum Matcher: Equatable { case light, hmm(HMMTuning.CandidateRadius, guarded: Bool) }

    static func match(_ fixes: [MatchFix], _ c: OracleCase, _ matcher: Matcher, graph: HMMGraph?) -> MatchResult {
        switch matcher {
        case .light: LightMatcher.match(fixes, network: c.network)
        case .hmm(let radius, let guarded):
            HMMMatcher.match(fixes, graph: graph ?? HMMGraph(c.network), radius: radius, countingGuard: guarded)
        }
    }

    static func run(_ c: OracleCase, _ matcher: Matcher) -> (PassScore.Counts, [String]) {
        var total = PassScore.Counts()
        var notes: [String] = []
        let graph = matcher == .light ? nil : HMMGraph(c.network)
        for d in c.drives {
            let r = Self.match(d.fixes, c, matcher, graph: graph)
            let predicted = r.passes.map(\.nodeId)
            let s = PassScore.score(predicted: predicted, truth: d.passes)
            total = total + s
            if s.truePositives != s.truth || s.truePositives != s.predicted {
                let missed = Set(d.passes).subtracting(predicted).sorted()
                let extra = Set(predicted).subtracting(d.passes).sorted()
                notes.append("  \(d.label): tp \(s.truePositives) pred \(s.predicted) truth \(s.truth) runs \(r.runs) missed \(missed.prefix(8)) extra \(extra.prefix(8))")
            }
        }
        return (total, notes)
    }

    static let strictCases: Set<Int> = [1, 2, 4, 5, 6, 8, 9]

    /// The first measurement (SPEC 14.4 "start with a light matcher"): printed for the record, not
    /// asserted, because it missed the acceptance and the parent's HMM was ported.
    @Test func lightMatcherMeasurement() throws {
        var lines = ["LIGHT light matcher, first measurement (not used for trip statistics)"]
        for n in Self.allCases {
            let c = try OracleCase.load(n)
            let (s, _) = Self.run(c, .light)
            lines.append(String(format: "LIGHT case %d: truth %d pred %d tp %d precision %.1f %% recall %.1f %%",
                                n, s.truth, s.predicted, s.truePositives, s.precision * 100, s.recall * 100))
        }
        print(lines.joined(separator: "\n"))
    }

    /// The unmodified port and the rejected alternative, for the record, not asserted: the port
    /// without the counting guard matched parking-lot fixes onto Park Lane (case 9); the SPEC
    /// radius used for matching was not robust (see `robustnessSweep`).
    @Test func hmmVariantsMeasurement() throws {
        var lines = ["VARIANT HMM variants, not used by Spur: port = parent radius without counting guard; spur-radius = matching with clamp(2 x acc, 12, 30)"]
        for (name, m) in [("port", Matcher.hmm(.parent, guarded: false)), ("spur-radius", Matcher.hmm(.spur, guarded: false))] {
            for n in Self.allCases {
                let c = try OracleCase.load(n)
                let (s, _) = Self.run(c, m)
                lines.append(String(format: "VARIANT %@ case %d: truth %d pred %d tp %d precision %.1f %% recall %.1f %%",
                                    name, n, s.truth, s.predicted, s.truePositives, s.precision * 100, s.recall * 100))
            }
        }
        print(lines.joined(separator: "\n"))
    }

    /// Robustness check, not asserted: ten more noise seeds per drive, and for cases 1 to 4 the same
    /// drives 7 m to the right of the centreline (an outer lane), with both candidate radii.
    @Test func robustnessSweep() throws {
        var lines = ["SWEEP case | variant | seeds: truth pred tp precision recall runs | lane 7 m: truth pred tp precision recall runs"]
        for n in Self.allCases {
            let c = try OracleCase.load(n)
            let root = try #require(try JSONSerialization.jsonObject(with: TestResources.data("oracle-sweep-case\(n)")) as? [String: Any])
            let sweep = root["sweep"] as? [[String: Any]] ?? []
            #expect(sweep.count == c.drives.count)
            let graph = HMMGraph(c.network)
            let variants: [(String, HMMTuning.CandidateRadius, Bool)] = [("spur (port+guard)", .parent, true), ("port", .parent, false), ("spur-radius", .spur, false)]
            for (name, radius, guarded) in variants {
                var seeds = PassScore.Counts(), lane = PassScore.Counts()
                var seedRuns = 0, laneRuns = 0
                var hasLane = false
                for (d, entry) in zip(c.drives, sweep) {
                    for seed in entry["seeds"] as? [[String: Any]] ?? [] {
                        let r = HMMMatcher.match(Self.fixes(seed["fixes"]), graph: graph, radius: radius, countingGuard: guarded)
                        seeds = seeds + PassScore.score(predicted: r.passes.map(\.nodeId), truth: d.passes)
                        seedRuns += r.runs
                    }
                    if let l = entry["lane"] as? [String: Any] {
                        hasLane = true
                        let r = HMMMatcher.match(Self.fixes(l["fixes"]), graph: graph, radius: radius, countingGuard: guarded)
                        lane = lane + PassScore.score(predicted: r.passes.map(\.nodeId), truth: d.passes)
                        laneRuns += r.runs
                    }
                }
                let laneText = hasLane ? String(format: "%d %d %d %.1f %% %.1f %% %d", lane.truth, lane.predicted, lane.truePositives,
                                                lane.precision * 100, lane.recall * 100, laneRuns) : "-"
                lines.append(String(format: "SWEEP %d | %@ | %d %d %d %.1f %% %.1f %% %d | %@", n, name, seeds.truth, seeds.predicted,
                                    seeds.truePositives, seeds.precision * 100, seeds.recall * 100, seedRuns, laneText))
            }
        }
        print(lines.joined(separator: "\n"))
    }

    static func fixes(_ any: Any?) -> [MatchFix] {
        (any as? [[String: Any]] ?? []).map { f in
            MatchFix(time: (f["t"] as! NSNumber).doubleValue / 1000, lat: (f["lat"] as! NSNumber).doubleValue,
                     lon: (f["lon"] as! NSNumber).doubleValue, accuracy: (f["accuracy"] as? NSNumber)?.doubleValue,
                     speed: (f["speed"] as? NSNumber)?.doubleValue, course: (f["heading"] as? NSNumber)?.doubleValue)
        }
    }

    /// SPEC 14.4: case 6 (downtown grid, 60 s at a red light) has exactly one stop, classified at a
    /// signal. Spur's own stop rule on the oracle fixes, classified against the matched path.
    @Test func case6HasExactlyOneStopAtASignal() throws {
        let c = try OracleCase.load(6)
        let d = c.drives[0]
        let fixes = d.fixes.map { f in
            Fix(timestampMs: Int64((f.time * 1000).rounded()), latitude: f.lat, longitude: f.lon, horizontalAccuracy: f.accuracy,
                speed: f.speed, course: f.course)
        }
        let stops = StopStats.stops(Track(fixes: fixes, config: .default))
        #expect(stops.count == 1)
        let stop = try #require(stops.first)
        #expect(stop.duration >= 55 && stop.duration <= 65)
        let r = HMMMatcher.match(d.fixes, network: c.network)
        let at = RoadStops.standingPoint(stop, fixes: fixes)
        let kind = RoadStops.classify(at, pathNodes: RoadStops.pathNodes(r, net: c.network), net: c.network)
        let case6 = try #require(c.root["case6"] as? [String: Any])
        let signal = (case6["signalNode"] as! NSNumber).int64Value
        let distance = OSMGeo.haversine(at, try #require(c.network.features[signal]).position)
        print(String(format: "CASE6 stops %d, duration %.1f s, classified %@, %.1f m from signal node %lld", stops.count, stop.duration,
                     kind.rawValue, distance, signal))
        #expect(kind == .signal)
        #expect(distance <= RoadConstants.stopFeatureRadiusM)
    }

    /// SPEC 14.4 acceptance, asserted, for the matcher the trip analysis uses: the parent's HMM,
    /// unchanged, with the counting guard.
    @Test func acceptanceTable() throws {
        var lines = ["ACCEPTANCE HMM matcher (feature passes, node level, pooled per case)",
                     "ACCEPTANCE case | fixture                        | drives | truth | pred |  tp | precision | recall | need P/R   | result"]
        var allPass = true
        for n in Self.allCases {
            let c = try OracleCase.load(n)
            let (s, notes) = Self.run(c, .hmm(.parent, guarded: true))
            let strict = Self.strictCases.contains(n)
            let ok = strict ? (s.precision >= 0.95 && s.recall >= 0.90) : s.precision >= 0.90
            allPass = allPass && ok
            lines.append(String(format: "ACCEPTANCE %4d | %-30@ | %6d | %5d | %4d | %3d | %8.1f %% | %5.1f %% | %@ | %@",
                                n, c.fixture, c.drives.count, s.truth, s.predicted, s.truePositives, s.precision * 100, s.recall * 100,
                                strict ? ">=95/>=90 " : ">=90/doc  ", ok ? "PASS" : "FAIL"))
            for note in notes { lines.append("ACCEPTANCE \(note)") }
        }
        print(lines.joined(separator: "\n"))
        #expect(allPass, "\(lines.joined(separator: "\n"))")
    }
}
