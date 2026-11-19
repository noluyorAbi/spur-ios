import Foundation
import Observation

/// The suggestions for a trip's gaps and the owner's decisions (SPEC 18.8).
@MainActor @Observable
final class GapFillModel {
    struct Item: Identifiable, Equatable {
        var id: String
        var startMs: Int64
        var endMs: Int64
        var seconds: Double
        /// The suggestion as a fill, nil with a reason.
        var fill: GapFill?
        var reason: String?
        var status: GapFill.Status?
    }

    private(set) var items: [Item] = []
    private(set) var file = GapFillFile()
    private(set) var loading = false
    @ObservationIgnored private var loadedFor: UUID?

    var acceptedMeters: Double { file.acceptedMeters }

    /// Features on accepted fills, the "ergänzt" bucket: "2 Ampeln, 1 Stoppschild".
    var filledFeatures: String? {
        var total: [ScenarioFinder.Feature: Int] = [:]
        for f in file.accepted { for (k, v) in f.features { if let feature = ScenarioFinder.Feature(rawValue: k) { total[feature, default: 0] += v } } }
        let parts = ScenarioFinder.Feature.allCases.compactMap { f -> String? in
            guard let n = total[f], n > 0 else { return nil }
            return "\(n) \(n == 1 ? f.nouns.0 : f.nouns.1)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    func load(trip id: UUID, ends: [(a: Fix, b: Fix)], store: TripStore, roads: RoadService) async {
        guard loadedFor != id else { return }
        loadedFor = id
        loading = true
        defer { loading = false }
        file = store.loadGapFills(id)
        var out: [Item] = []
        for (a, b) in ends {
            let key = "\(a.timestampMs)-\(b.timestampMs)"
            var item = Item(id: key, startMs: a.timestampMs, endMs: b.timestampMs, seconds: b.time - a.time)
            item.status = file.fills.first { $0.id == key }?.status
            if let stored = file.fills.first(where: { $0.id == key && $0.status == .accepted }) {
                item.fill = stored
                out.append(item)
                continue
            }
            let pa = LatLon(lat: a.latitude, lon: a.longitude), pb = LatLon(lat: b.latitude, lon: b.longitude)
            let straight = OSMGeo.haversine(pa, pb)
            guard straight >= GapFiller.minStraightM else {
                item.reason = GapFiller.NoSuggestion.tooShort.rawValue
                out.append(item)
                continue
            }
            let mid = LatLon(lat: (pa.lat + pb.lat) / 2, lon: (pa.lon + pb.lon) / 2)
            let data = await roads.scenarioData(around: mid, radiusM: straight / 2 + 1500)
            let ea = GapFiller.End(position: pa, course: a.course, accuracy: a.horizontalAccuracy ?? 10)
            let eb = GapFiller.End(position: pb, course: b.course, accuracy: b.horizontalAccuracy ?? 10)
            let seconds = item.seconds
            let result = await Task.detached(priority: .userInitiated) { () -> (GapFill?, String?) in
                guard !data.segments.isEmpty else { return (nil, GapFiller.NoSuggestion.noRoadData.rawValue) }
                let g = DiscoveryPlanner.graph(segments: data.segments, features: [], chips: [], onlyMissing: false) { _, _ in false }
                switch GapFiller.suggest(from: ea, to: eb, elapsed: seconds, graph: g) {
                case .success(let s): return (s.fill(startMs: a.timestampMs, endMs: b.timestampMs, graph: g, features: data.features), nil)
                case .failure(let r): return (nil, r.rawValue)
                }
            }.value
            item.fill = result.0
            item.reason = result.1
            out.append(item)
        }
        items = out
    }

    func accept(_ item: Item, trip id: UUID, store: TripStore) {
        guard var fill = item.fill else { return }
        fill.status = .accepted
        file.decide(fill)
        save(id, store)
    }

    func reject(_ item: Item, trip id: UUID, store: TripStore) {
        file.decide(GapFill(startMs: item.startMs, endMs: item.endMs, status: .rejected))
        save(id, store)
    }

    func undo(_ item: Item, trip id: UUID, store: TripStore) {
        file.undo(item.id)
        save(id, store)
    }

    private func save(_ id: UUID, _ store: TripStore) {
        try? store.saveGapFills(file, for: id)
        for k in items.indices { items[k].status = file.fills.first { $0.id == items[k].id }?.status }
    }

    /// "Lücke 3 min 12 s, 2,4 km, vermutlich über Telge Rd".
    static func text(_ item: Item) -> String {
        let m = Int(item.seconds) / 60, s = Int(item.seconds) % 60
        let time = m > 0 ? "\(m) min \(s) s" : "\(s) s"
        guard let fill = item.fill else { return "Lücke \(time): \(item.reason ?? "kein Vorschlag")" }
        let km = String(format: "%.1f", fill.lengthM / 1000).replacingOccurrences(of: ".", with: ",")
        let via = fill.streets.first.map { ", vermutlich über \($0)" } ?? ""
        return "Lücke \(time), \(km) km\(via)"
    }
}
