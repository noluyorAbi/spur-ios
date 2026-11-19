import Foundation
import Testing
@testable import Spur

/// SPEC 16.3.4: the motion sensor in the exports, and old trips exporting as before.
struct MotionExportTests {
    static let scenario = MotionTests.build(MotionTests.standard())

    /// A finished trip of the standard drive in `store`, with `motion.bin`, its analysis and the
    /// summary in trip.json when `motion` is true; fixes only otherwise.
    static func trip(in store: TripStore, motion: Bool, offsetMs: Int64 = 0) throws -> TripRecord {
        let s = scenario
        let fixes = Fixtures.shifted(s.fixes, byMs: offsetMs)
        var r = TripLifecycle.finalized(TripRecord(startedAt: fixes[0].date, isRecording: false),
                                        contents: FixFile.Contents(fixes: fixes), config: .default)
        let samples = s.samples.map { var x = $0; x.time += Double(offsetMs) / 1000; return x }
        if motion {
            let out = MotionAnalyzer.analyze(samples: samples, fixes: fixes)
            r.motion = out.summary
            try store.create(r)
            try store.saveMotionDetails(out.details, for: r.id)
            let w = try MotionFileWriter(url: store.motionURL(r.id), rateHz: 100)
            try w.append(samples)
            w.close()
        } else {
            try store.create(r)
        }
        let w = try store.openWriter(r.id)
        for f in fixes { try w.append(f) }
        w.close()
        return r
    }

    @Test func fastNumbersMatchNumFixed() {
        var noise = MotionSynth.Noise(state: 5)
        var mismatches: [String] = []
        for k in 0..<20_000 {
            let digits = k % 7
            let v = noise.gauss() * pow(10, Double(k % 12) - 4)
            if FastNum.string(v, digits) != Num.fixed(v, digits) { mismatches.append("\(v) at \(digits)") }
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(5))")
        #expect(FastNum.string(-0.0004, 3) == "0")
        #expect(FastNum.string(1_794_420_000.123456, 6) == "1794420000.123456")
        #expect(FastNum.string(-2.5, 3) == "-2.5")
        #expect(FastNum.string(.nan, 3) == "")
    }

    @Test func theSensorCSVHasEverySampleTheRawChannelsAndTheVehicleFrame() throws {
        let s = Self.scenario
        let csv = MotionCSVExporter.export(samples: s.samples, fixes: s.fixes)
        #expect(csv.hasSuffix("\n"))
        let lines = csv.split(separator: "\n")
        #expect(lines.first.map(String.init) == MotionCSVExporter.header)
        #expect(lines.count == s.samples.count + 1)
        let columns = MotionCSVExporter.header.split(separator: ",").count
        #expect(columns == 19)
        var badRows = 0, aligned = 0, handled = 0
        var minLong = 0.0
        for (i, line) in lines.dropFirst().enumerated() {
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            let sample = s.samples[i]
            guard f.count == columns, let t = Double(f[0]), abs(t - sample.time) <= 1e-6,
                  let ax = Double(f[1]), abs(ax - Double(sample.userAcceleration.x)) <= 1e-6,
                  let qw = Double(f[13]), abs(qw - Double(sample.attitude.w)) <= 1e-6,
                  Double(f[16]) != nil else { badRows += 1; continue }
            if f[17] == "1" {
                aligned += 1
                guard let long = Double(f[14]), Double(f[15]) != nil else { badRows += 1; continue }
                minLong = min(minLong, long)
            } else if !f[14].isEmpty || !f[15].isEmpty {
                badRows += 1
            }
            if f[18] == "1" { handled += 1 }
        }
        print("MOTION CSV: \(lines.count - 1) rows, aligned \(aligned), handled \(handled), min long \(minLong)")
        #expect(badRows == 0)
        #expect(Double(aligned) / Double(s.samples.count) > 0.9, "both segments are aligned")
        #expect(minLong < -5.5, "the hard brake (truth -6 m/s²) in the raw vehicle frame")
        #expect(handled > 0, "the remount is flagged")
    }

    @Test func theChunkedFileEqualsTheString() throws {
        let s = Self.scenario
        let url = Fixtures.tempDir().appendingPathComponent("sensordaten.csv")
        try MotionCSVExporter.write(samples: s.samples, fixes: s.fixes, to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == MotionCSVExporter.export(samples: s.samples, fixes: s.fixes))
    }

    @Test func eventsReachGPXGeoJSONJSONAndTripsCSV() throws {
        let store = TripStore(root: Fixtures.tempDir())
        let r = try Self.trip(in: store, motion: true)
        let input = try ExportService.input(for: r.id, store: store, config: .default)
        let details = try #require(input.motion)
        let located = details.events.filter { $0.latitude != nil && $0.longitude != nil }
        #expect(located.count == 6, "1 brake, 1 acceleration, 1 left, 1 right, 2 bumps")

        let gpx = GPXExporter.export(input)
        #expect(gpx.components(separatedBy: "<type>motion.").count - 1 == located.count)
        #expect(gpx.contains("<name>Starke Bremsung</name>") && gpx.contains("<type>motion.hardBraking</type>"))
        #expect(gpx.contains("<type>motion.bump</type>"))

        let geo = try #require(try JSONSerialization.jsonObject(with: Data(GeoJSONExporter.export(input).utf8)) as? [String: Any])
        let points = (geo["features"] as? [[String: Any]] ?? []).filter { ($0["properties"] as? [String: Any])?["kind"] as? String == "motionEvent" }
        #expect(points.count == located.count)
        #expect(points.contains { ($0["properties"] as? [String: Any])?["type"] as? String == "motion.lateralLeft" })

        let doc = try #require(try JSONSerialization.jsonObject(with: JSONExporter.export(input)) as? [String: Any])
        let events = doc["motionEvents"] as? [[String: Any]] ?? []
        #expect(events.count == details.events.count)
        #expect(events.contains { $0["type"] as? String == "motion.hardBraking" && ($0["peak"] as? Double ?? 0) < -5.5 })
        let motion = (doc["trip"] as? [String: Any])?["motion"] as? [String: Any]
        #expect((motion?["counts"] as? [String: Any])?["bumps"] as? Int == 2)

        let csv = TripsSummaryCSV.export([(input.record, input.statistics)])
        let rows = csv.split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        #expect(rows[0].count == rows[1].count)
        #expect(Array(rows[0].suffix(3)) == ["hard_accelerations", "lateral_events", "bumps"])
        let tail = Array(rows[1].suffix(MotionSummaryColumns.count))
        #expect(tail[2] == "true" && tail[9] == "1" && tail[10] == "1" && tail[11] == "1" && tail[12] == "2" && tail[13] == "2", "\(tail)")
        #expect(Double(tail[3]) ?? 0 >= 0.9 && Double(tail[4]) ?? 0 >= 0.9, "r_long and r_lat in their own columns")
    }

    @Test func aTripWithoutMotionExportsWithoutAnyMotionTrace() throws {
        let store = TripStore(root: Fixtures.tempDir())
        let r = try Self.trip(in: store, motion: false)
        let input = try ExportService.input(for: r.id, store: store, config: .default)
        #expect(input.motion == nil)
        // Details without a summary in trip.json (an inconsistent folder) are ignored as well.
        let stray = TripExportInput(record: r, fixes: input.fixes, events: [],
                                    motion: MotionAnalyzer.analyze(samples: Self.scenario.samples, fixes: Self.scenario.fixes).details)
        for i in [input, stray] {
            #expect(!GPXExporter.export(i).contains("motion"))
            #expect(!GeoJSONExporter.export(i).contains("motion"))
            let json = String(decoding: try JSONExporter.export(i), as: UTF8.self)
            #expect(!json.contains("motion"))
            #expect(!CSVExporter.export(i).contains("motion"))
        }
        let csv = TripsSummaryCSV.export([(input.record, input.statistics)])
        let rows = csv.split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        #expect(rows[0].count == rows[1].count)
        let tail = Array(rows[1].suffix(MotionSummaryColumns.count))
        #expect(tail == Array(repeating: "", count: MotionSummaryColumns.count))
    }

    @Test func theZipCarriesMotionBinAndItsDescription() throws {
        let store = TripStore(root: Fixtures.tempDir())
        let with = try Self.trip(in: store, motion: true)
        let without = try Self.trip(in: store, motion: false, offsetMs: 3_600_000)
        let zip = try ExportService.exportAll(store: store, config: .default, documents: Fixtures.tempDir(), temp: Fixtures.tempDir())
        let raw = String(decoding: try Data(contentsOf: zip), as: UTF8.self)
        let stemWith = TripExportInput(record: with, fixes: [], events: []).fileStem
        let stemWithout = TripExportInput(record: without, fixes: [], events: []).fileStem
        #expect(raw.contains("\(stemWith)/motion.bin"))
        #expect(!raw.contains("\(stemWithout)/motion.bin"))
        #expect(raw.contains("MOTION-FORMAT.md"))

        let plain = TripStore(root: Fixtures.tempDir())
        _ = try Self.trip(in: plain, motion: false)
        let zip2 = try ExportService.exportAll(store: plain, config: .default, documents: Fixtures.tempDir(), temp: Fixtures.tempDir())
        #expect(!String(decoding: try Data(contentsOf: zip2), as: UTF8.self).contains("MOTION-FORMAT.md"))
    }

    @Test func theBundledFormatDescriptionIsTheRepositoryFile() throws {
        let bundled = try #require(ExportService.motionFormatDoc)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/MOTION-FORMAT.md")
        #expect(try Data(contentsOf: bundled) == Data(contentsOf: repo))
    }

    @Test func theSensorCSVExportWritesTheShareFileAndTheExportsCopy() throws {
        let store = TripStore(root: Fixtures.tempDir())
        let r = try Self.trip(in: store, motion: true)
        let docs = Fixtures.tempDir()
        let url = try ExportService.exportMotionCSV(r.id, store: store, documents: docs, temp: Fixtures.tempDir())
        let stem = TripExportInput(record: r, fixes: [], events: []).fileStem
        #expect(url.lastPathComponent == "\(stem)-sensordaten.csv")
        let copy = ExportService.exportsFolder(documents: docs).appendingPathComponent(url.lastPathComponent)
        #expect(try Data(contentsOf: copy) == Data(contentsOf: url))
        #expect(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count == Self.scenario.samples.count + 1)

        let plain = try Self.trip(in: store, motion: false, offsetMs: 3_600_000)
        #expect(throws: ExportService.ExportError.self) {
            try ExportService.exportMotionCSV(plain.id, store: store, documents: docs, temp: Fixtures.tempDir())
        }
    }

    @Test func storageCountsOnlyMotionFilesAndTheSettingStatesThePerHourSize() throws {
        let store = TripStore(root: Fixtures.tempDir())
        _ = try Self.trip(in: store, motion: true)
        _ = try Self.trip(in: store, motion: false, offsetMs: 3_600_000)
        #expect(store.motionBytes() == Int64(MotionFile.headerSize + MotionFile.recordSize * Self.scenario.samples.count))
        #expect(SettingsView.motionPerHour(100) == "etwa 22 MB pro Stunde bei 100 Hz")
        #expect(SettingsView.motionPerHour(50) == "etwa 11 MB pro Stunde bei 50 Hz")
    }
}
