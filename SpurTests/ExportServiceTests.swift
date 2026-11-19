import Foundation
import Testing
@testable import Spur

struct ExportServiceTests {
    /// A store with `count` finished trips of 20 fixes each.
    static func store(trips count: Int) throws -> (TripStore, [TripRecord]) {
        let store = TripStore(root: Fixtures.tempDir())
        var records: [TripRecord] = []
        for k in 0..<count {
            let fixes = Fixtures.northbound(speeds: Array(repeating: 20, count: 20), startMs: Fixtures.baseMs + Int64(k) * 3_600_000)
            var r = TripRecord(startedAt: fixes[0].date, isRecording: false)
            r.customTitle = "Testfahrt \(k), mit Komma"
            r = TripLifecycle.finalized(r, contents: FixFile.Contents(fixes: fixes), config: .default)
            try store.create(r)
            let w = try store.openWriter(r.id)
            for f in fixes { try w.append(f) }
            w.close()
            records.append(r)
        }
        return (store, records)
    }

    @Test func singleTripWritesFourFilesAndCopiesThemToExports() throws {
        let (store, records) = try Self.store(trips: 1)
        let docs = Fixtures.tempDir()
        let urls = try ExportService.exportTrip(records[0].id, store: store, config: .default, documents: docs, temp: Fixtures.tempDir())
        #expect(urls.map(\.pathExtension) == ["gpx", "csv", "geojson", "json"])
        let exported = try FileManager.default.contentsOfDirectory(atPath: ExportService.exportsFolder(documents: docs).path).sorted()
        #expect(exported == urls.map(\.lastPathComponent).sorted())
        let csv = try String(contentsOf: urls[1], encoding: .utf8)
        #expect(csv.split(separator: "\n").count == 21)
        #expect(urls[0].lastPathComponent == "spur-2026-11-11T180000Z.gpx")
    }

    @Test func allTripsZipHoldsEveryTripAndTheSummary() throws {
        let (store, records) = try Self.store(trips: 3)
        // A running trip is not exported.
        try store.create(TripRecord(startedAt: Date(), isRecording: true))
        let docs = Fixtures.tempDir()
        let now = Date(timeIntervalSince1970: 1_794_430_000)
        let zip = try ExportService.exportAll(store: store, config: .default, now: now, documents: docs, temp: Fixtures.tempDir())
        #expect(zip.lastPathComponent == "spur-alle-fahrten-2026-11-11T204640Z.zip")
        #expect(zip.deletingLastPathComponent() == ExportService.exportsFolder(documents: docs))
        let data = try Data(contentsOf: zip)
        // Local file header signature of a ZIP archive.
        #expect(data.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))
        // Entry names are stored uncompressed in the archive.
        let raw = String(decoding: data, as: UTF8.self)
        #expect(raw.contains("trips.csv"))
        for r in records {
            let stem = TripExportInput(record: r, fixes: [], events: []).fileStem
            for ext in ["gpx", "csv", "geojson", "json"] {
                #expect(raw.contains("\(stem)/\(stem).\(ext)"), "missing \(stem).\(ext)")
            }
        }
    }

    @Test func tripsWithTheSameStartSecondGetDistinctFolders() throws {
        let store = TripStore(root: Fixtures.tempDir())
        let fixes = Fixtures.northbound(speeds: Array(repeating: 20, count: 5))
        for _ in 0..<2 {
            let r = TripLifecycle.finalized(TripRecord(startedAt: fixes[0].date, isRecording: false),
                                            contents: FixFile.Contents(fixes: fixes), config: .default)
            try store.create(r)
        }
        let zip = try ExportService.exportAll(store: store, config: .default, documents: Fixtures.tempDir(), temp: Fixtures.tempDir())
        let raw = String(decoding: try Data(contentsOf: zip), as: UTF8.self)
        #expect(raw.contains("spur-2026-11-11T180000Z/"))
        #expect(raw.contains("spur-2026-11-11T180000Z-"))
    }
}
