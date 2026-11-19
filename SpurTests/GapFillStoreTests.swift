import CryptoKit
import Foundation
import Testing
@testable import Spur

/// SPEC 18.8: decisions on gap fills never touch the raw files; fills count where they should.
struct GapFillStoreTests {
    static func fill(_ start: Int64) -> GapFill {
        let a = LatLon(lat: 32.78, lon: -96.80), b = LatLon(lat: 32.78, lon: -96.799)
        return GapFill(startMs: start, endMs: start + 60_000, status: .accepted,
                       edges: [GapFill.Edge(wayId: 7, a: 1, b: 2, forward: true, ca: a, cb: b)],
                       coords: [a, b], lengthM: 94, streets: ["Elm St"], features: ["signals": 2])
    }

    static func hash(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    }

    @MainActor
    @Test func acceptRejectAndUndoLeaveTheRawFilesByteIdentical() async throws {
        let r = EngineTests.rig()
        r.engine.requestStart()
        let id = r.engine.trip!.id
        r.engine.handle(EngineTests.freshFixes(30))
        r.engine.stop()
        try await EngineTests.waitUntilIdle(r.engine)
        let fixesBefore = Self.hash(r.store.fixesURL(id)), motionBefore = Self.hash(r.store.motionURL(id))
        #expect(fixesBefore != nil)
        let m = GapFillModel()
        let item = GapFillModel.Item(id: Self.fill(1000).id, startMs: 1000, endMs: 61_000, seconds: 60, fill: Self.fill(1000))
        m.accept(item, trip: id, store: r.store)
        #expect(r.store.loadGapFills(id).accepted.count == 1)
        m.reject(item, trip: id, store: r.store)
        #expect(r.store.loadGapFills(id).fills.first?.status == .rejected && r.store.loadGapFills(id).accepted.isEmpty)
        m.undo(item, trip: id, store: r.store)
        #expect(r.store.loadGapFills(id).fills.isEmpty)
        m.accept(item, trip: id, store: r.store)
        #expect(Self.hash(r.store.fixesURL(id)) == fixesBefore, "fixes.jsonl byte-identical")
        #expect(Self.hash(r.store.motionURL(id)) == motionBefore, "motion.bin byte-identical (or absent both times)")
        #expect(m.acceptedMeters == 94)
        #expect(m.filledFeatures == "2 Ampeln")
    }

    @Test func acceptedFillsCountAsInferredCoverageAndPasses() {
        var file = GapFillFile()
        file.decide(Self.fill(1000))
        file.decide(GapFill(startMs: 5000, endMs: 9000, status: .rejected))
        let c = file.coverage()
        let edges = RoadCoverage.edges(c)
        #expect(edges.count == 1 && edges[0].inferred && edges[0].forwardPasses == 1)
        // Merged with a trip that drove the same edge, it is no longer only inferred.
        let driven = TripCoverage(runs: [CoverageRun(wayId: 7, nodes: [1, 2], coords: [LatLon(lat: 32.78, lon: -96.80), LatLon(lat: 32.78, lon: -96.799)],
                                                     forward: true, backward: false)])
        let merged = RoadCoverage.merge([driven, c])
        #expect(merged.count == 1 && !merged[0].inferred && merged[0].forwardPasses == 2)
        let heat = RoadCoverage.heatLines(RoadCoverage.merge([c]))
        #expect(heat.first.map { RoadCoverage.heatInfo($0).contains("ergänzt") } == true)
    }

    @Test func exportsCarryTheFillApartFromTheTrack() {
        var input = TripExportInput(record: TripRecord(startedAt: Date(timeIntervalSince1970: 1_700_000_000), isRecording: false),
                                    fixes: Fixtures.northbound(speeds: Array(repeating: 12, count: 20)), events: [])
        input.fills = [Self.fill(1_700_000_010_000)]
        let gpx = GPXExporter.export(input)
        #expect(gpx.contains("<rte>") && gpx.contains("<name>Ergänzt (Lücke)</name>"))
        #expect(gpx.components(separatedBy: "<trk>").count - 1 == 1, "only the recorded track")
        #expect(gpx.components(separatedBy: "<rtept ").count - 1 == 2, "the fill as route points")
        #expect(gpx.components(separatedBy: "<trkpt ").count - 1 == 20, "track points are the 20 fixes only")
        let geo = GeoJSONExporter.export(input)
        #expect(geo.contains("\"filled\":true") && geo.contains("\"gapFill\""))
    }
}
