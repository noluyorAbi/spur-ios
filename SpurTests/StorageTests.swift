import CoreLocation
import Foundation
import Testing
@testable import Spur

struct FixModelTests {
    @Test func copiesEveryLocationField() {
        let t = Date(timeIntervalSince1970: 1_794_420_000.1234)
        let l = CLLocation(
            coordinate: .init(latitude: 32.776712345678, longitude: -96.797012345678),
            altitude: 151.25, horizontalAccuracy: 3.5, verticalAccuracy: 2.5,
            course: 91.5, courseAccuracy: 4, speed: 13.4, speedAccuracy: 0.6, timestamp: t
        )
        let f = Fix(location: l)
        #expect(f.timestampMs == 1_794_420_000_123)
        #expect(f.latitude == 32.776712345678)
        #expect(f.longitude == -96.797012345678)
        #expect(f.horizontalAccuracy == 3.5)
        #expect(f.altitude == 151.25)
        #expect(f.verticalAccuracy == 2.5)
        #expect(f.speed == 13.4)
        #expect(f.speedAccuracy == 0.6)
        #expect(f.course == 91.5)
        #expect(f.courseAccuracy == 4)
        #expect(f.ellipsoidalAltitude != nil)
    }

    @Test func invalidValuesBecomeNil() {
        let l = CLLocation(
            coordinate: .init(latitude: 1, longitude: 2), altitude: 10, horizontalAccuracy: -1,
            verticalAccuracy: -1, course: -1, courseAccuracy: -1, speed: -1, speedAccuracy: -1,
            timestamp: Date(timeIntervalSince1970: 0)
        )
        let f = Fix(location: l)
        #expect(f.horizontalAccuracy == nil)
        #expect(f.altitude == nil)
        #expect(f.ellipsoidalAltitude == nil)
        #expect(f.verticalAccuracy == nil)
        #expect(f.speed == nil)
        #expect(f.speedAccuracy == nil)
        #expect(f.course == nil)
        #expect(f.courseAccuracy == nil)
    }
}

struct FixFileTests {
    static let sample = Fix(
        timestampMs: 1_794_420_000_123, latitude: 32.776712345678901, longitude: -96.79701234567891,
        horizontalAccuracy: 3.5, altitude: 151.25, ellipsoidalAltitude: 125.75, verticalAccuracy: 2.5,
        speed: 13.4, speedAccuracy: 0.6, course: 359.99, courseAccuracy: 4, isSimulatedBySoftware: false,
        isProducedByAccessory: true
    )

    @Test func roundTripKeepsEveryFieldAndFullPrecision() throws {
        let url = Fixtures.tempDir().appendingPathComponent(FixFile.fileName)
        let partial = Fix(timestampMs: 1_794_420_001_000, latitude: 0.000001, longitude: -0.5)
        let gap = Gap(startMs: 1_794_420_001_000, endMs: 1_794_420_020_000, reason: .relaunch)
        let writer = try FixFileWriter(url: url)
        try writer.append(Self.sample)
        try writer.append(partial)
        try writer.append(gap)
        try writer.sync()
        writer.close()

        let parsed = FixFile.parse(try Data(contentsOf: url))
        #expect(parsed.headerVersion == 1)
        #expect(parsed.fixes == [Self.sample, partial])
        #expect(parsed.gaps == [gap])
        #expect(parsed.skippedLines == 0)
    }

    @Test func nullIsWrittenForInvalidValues() {
        let line = FixFile.line(for: Fix(timestampMs: 5, latitude: 1, longitude: 2))
        #expect(line == "{\"t\":5,\"lat\":1,\"lon\":2,\"hAcc\":null,\"alt\":null,\"ellAlt\":null,\"vAcc\":null,\"spd\":null,\"spdAcc\":null,\"crs\":null,\"crsAcc\":null,\"sim\":null,\"acc\":null}\n")
    }

    @Test func truncatedLastRecordIsTolerated() throws {
        let fixes = Fixtures.northbound(speeds: [10, 10, 10])
        var text = FixFile.header
        for f in fixes { text += FixFile.line(for: f) }
        let full = FixFile.line(for: Fixtures.shifted([fixes[2]], byMs: 1000)[0])
        text += String(full.prefix(full.count / 2)) // crash mid-write, no newline
        let parsed = FixFile.parse(Data(text.utf8))
        #expect(parsed.fixes == fixes)
        #expect(parsed.skippedLines == 1)
    }

    @Test func writerResumesCleanlyAfterATruncatedRecord() throws {
        let url = Fixtures.tempDir().appendingPathComponent(FixFile.fileName)
        let fixes = Fixtures.northbound(speeds: [10, 10, 10, 10])
        do {
            let w = try FixFileWriter(url: url)
            try w.append(fixes[0])
            try w.appendRaw(Data("{\"t\":123,\"lat\":4".utf8))
            w.close()
        }
        let w2 = try FixFileWriter(url: url)
        try w2.append(fixes[1])
        w2.close()
        let parsed = FixFile.parse(try Data(contentsOf: url))
        #expect(parsed.fixes == [fixes[0], fixes[1]])
        #expect(parsed.skippedLines == 1)
    }

    @Test func parsesFileWithoutTrailingNewline() {
        let f = Fixtures.northbound(speeds: [5])[0]
        var text = FixFile.header + FixFile.line(for: f)
        text.removeLast()
        #expect(FixFile.parse(Data(text.utf8)).fixes == [f])
    }
}

struct TripStoreTests {
    @Test func createSaveLoadAndIndexNewestFirst() throws {
        let store = TripStore(root: Fixtures.tempDir())
        let older = TripRecord(startedAt: Date(timeIntervalSince1970: 1_000_000), isRecording: false)
        var newer = TripRecord(startedAt: Date(timeIntervalSince1970: 2_000_000.5), isRecording: true)
        newer.note = "Notiz mit \"Anführungszeichen\""
        newer.gaps = [Gap(startMs: 1, endMs: 9000, reason: .background)]
        try store.create(older)
        try store.create(newer)

        let index = store.index()
        #expect(index.map(\.id) == [newer.id, older.id])
        #expect(index[0] == newer)
        #expect(try store.load(newer.id) == newer)
        // Fix file exists with its header.
        let fixes = store.loadFixes(newer.id)
        #expect(fixes.headerVersion == 1)
        #expect(fixes.fixes.isEmpty)
    }

    @Test func tripJsonIsSchemaVersioned() throws {
        let store = TripStore(root: Fixtures.tempDir())
        let r = TripRecord(startedAt: Date(timeIntervalSince1970: 0))
        try store.create(r)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: store.tripURL(r.id))) as? [String: Any]
        #expect(obj?["schema"] as? Int == 1)
    }

    @Test func indexSkipsBrokenFoldersAndForeignNames() throws {
        let store = TripStore(root: Fixtures.tempDir())
        let ok = TripRecord(startedAt: Date())
        try store.create(ok)
        let broken = UUID()
        try FileManager.default.createDirectory(at: store.folder(broken), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: store.tripURL(broken))
        try FileManager.default.createDirectory(at: store.root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        #expect(store.index().map(\.id) == [ok.id])
    }

    @Test func eventsAndDelete() throws {
        let store = TripStore(root: Fixtures.tempDir())
        let r = TripRecord(startedAt: Date())
        try store.create(r)
        let e = TripEvent(id: UUID(), timestampMs: 42, latitude: 1, longitude: 2, altitude: nil, tag: .construction, note: nil)
        try store.saveEvents([e], for: r.id)
        #expect(store.loadEvents(r.id) == [e])
        try store.delete(r.id)
        #expect(store.index().isEmpty)
    }

    @Test func indexOfManyTripsIsFast() throws {
        let store = TripStore(root: Fixtures.tempDir())
        let stats = TripAnalyzer.analyze(fixes: Fixtures.northbound(speeds: Array(repeating: 20, count: 120))).statistics
        for k in 0..<300 {
            var r = TripRecord(startedAt: Date(timeIntervalSince1970: Double(k) * 3600), isRecording: false)
            r.statistics = stats
            try store.create(r)
        }
        let clock = ContinuousClock()
        var count = 0
        let elapsed = clock.measure { count = store.index().count }
        #expect(count == 300)
        #expect(elapsed < .seconds(1))
    }
}
