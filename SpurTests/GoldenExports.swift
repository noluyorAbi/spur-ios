import Foundation
@testable import Spur

/// SPEC 16.3.3 "old trip compatibility": the exports of trips written by 1.0 and 1.1, as files.
/// The golden files in `Fixtures/golden` were written by this same code at commit 99ad32f (the
/// last commit before the 1.2 exports), so comparing against them shows that 1.2 exports old
/// trips byte for byte as before, except `trips.csv`, which only gains trailing columns.
enum GoldenExports {
    struct Case {
        var name: String
        var input: TripExportInput
    }

    static func cases() throws -> [Case] {
        var out: [Case] = []
        for name in ["trip-v1.0-full", "trip-v1.0-recorded"] {
            let record = try TripStore.decoder().decode(TripRecord.self, from: TestResources.data(name))
            let startMs = Int64((record.startedAt.timeIntervalSince1970 * 1000).rounded())
            let fixes = Fixtures.northbound(speeds: [0, 4, 9, 14, 18, 20, 20, 20, 16, 11, 6, 2, 0, 0, 5, 12], startMs: startMs)
            let event = TripEvent(id: UUID(uuidString: "6F1B2D3C-0000-4000-8000-000000000001")!, timestampMs: fixes[6].timestampMs,
                                  latitude: fixes[6].latitude, longitude: fixes[6].longitude, altitude: 140,
                                  ellipsoidalAltitude: 112, tag: .hazard, note: "Schlagloch, rechte Spur")
            out.append(Case(name: name.replacingOccurrences(of: "trip-", with: ""),
                            input: TripExportInput(record: record, fixes: fixes, events: [event])))
        }
        var (roads, _) = try ExportRoadsTests.input()
        roads.record.id = UUID(uuidString: "6F1B2D3C-0000-4000-8000-000000000011")!
        out.append(Case(name: "v1.1-roads", input: roads))
        return out
    }

    /// The four per-trip files plus the trip's `trips.csv`.
    static func files(_ c: Case) throws -> [(name: String, data: Data)] {
        var files = try ExportService.Format.allCases.map { format in
            ("golden-\(c.name).\(format.fileExtension)", try ExportService.file(format, for: c.input).data)
        }
        files.append(("golden-\(c.name).trips.csv", Data(TripsSummaryCSV.export([(c.input.record, c.input.statistics)]).utf8)))
        return files
    }
}
