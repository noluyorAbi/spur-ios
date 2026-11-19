import Foundation
import Testing
@testable import Spur

/// Anchor for `Bundle(for:)`: the test bundle holds the JSON fixtures.
nonisolated final class TestBundleToken {}

nonisolated enum TestResources {
    static func url(_ name: String, _ ext: String = "json") throws -> URL {
        try #require(Bundle(for: TestBundleToken.self).url(forResource: name, withExtension: ext), "missing test resource \(name).\(ext)")
    }

    static func data(_ name: String, _ ext: String = "json") throws -> Data {
        try Data(contentsOf: url(name, ext))
    }
}

/// SPEC 14.0: the owner's iPhone holds trips written by version 1.0. Every change to `trip.json`
/// must be additive, so a record written by 1.0 (commit 8cf7717) decodes, and saving it again
/// keeps every old field with its old value.
struct CompatibilityTests {
    /// Every leaf of a JSON value with its path, for example `statistics.gps.fixCount`.
    static func leaves(_ value: Any, path: String = "", into out: inout [String: Any]) {
        if let dict = value as? [String: Any] {
            for (k, v) in dict { leaves(v, path: path.isEmpty ? k : "\(path).\(k)", into: &out) }
        } else if let array = value as? [Any] {
            out["\(path)#count"] = array.count
            for (i, v) in array.enumerated() { leaves(v, path: "\(path)[\(i)]", into: &out) }
        } else {
            out[path] = value
        }
    }

    static func same(_ a: Any, _ b: Any) -> Bool {
        if let x = a as? NSNumber, let y = b as? NSNumber { return x == y }
        if let x = a as? String, let y = b as? String { return x == y }
        if a is NSNull, b is NSNull { return true }
        return false
    }

    @Test(arguments: ["trip-v1.0-full", "trip-v1.0-recorded"])
    func tripJSONFromVersion10SurvivesASave(_ name: String) throws {
        let old = try TestResources.data(name)
        let record = try TripStore.decoder().decode(TripRecord.self, from: old)
        #expect(record.schema == 1)
        #expect(record.statistics != nil)

        // Save through the real store and read the file back.
        let store = TripStore(root: Fixtures.tempDir())
        try FileManager.default.createDirectory(at: store.folder(record.id), withIntermediateDirectories: true)
        try store.save(record)
        let saved = try Data(contentsOf: store.tripURL(record.id))

        var before: [String: Any] = [:]
        var after: [String: Any] = [:]
        Self.leaves(try JSONSerialization.jsonObject(with: old), into: &before)
        Self.leaves(try JSONSerialization.jsonObject(with: saved), into: &after)
        #expect(before.count > 40, "the fixture should be a full record")
        for (path, value) in before {
            let now = try #require(after[path], "field \(path) of a 1.0 trip.json was lost on save")
            #expect(Self.same(value, now), "field \(path) changed on save: \(value) became \(now)")
        }
        // And the reloaded record is the same value.
        #expect(try store.load(record.id) == record)
    }

    @Test func fixFileStaysAtFormatVersion1() throws {
        let store = TripStore(root: Fixtures.tempDir())
        let record = TripRecord(startedAt: Date())
        try store.create(record)
        let writer = try store.openWriter(record.id)
        try writer.append(Fixtures.northbound(speeds: [10, 10])[0])
        writer.close()
        let text = try String(contentsOf: store.fixesURL(record.id), encoding: .utf8)
        let header = try #require(text.split(separator: "\n").first)
        #expect(header == #"{"format":"spur-fixes","version":1}"#)
    }
}
