import Foundation
import Testing
@testable import Spur

/// SPEC 14.7: road data in the exports.
struct ExportRoadsTests {
    static func input() throws -> (TripExportInput, RoadAnalyzer.Output) {
        let c = try OracleCase.load(6)
        let fixes = RoadAnalysisTests.fixes(c.drives[0])
        let out = RoadAnalyzer.analyze(fixes: fixes, config: .default, now: Date(timeIntervalSince1970: 1_794_420_000)) { _ in
            RoadTileProvider.Lookup(elements: c.elements, sources: [:], missing: [])
        }
        var record = TripRecord(startedAt: fixes[0].date, isRecording: false)
        record.endedAt = fixes.last!.date
        record.roads = out.statistics
        return (TripExportInput(record: record, fixes: fixes, events: [], roads: out.details), out)
    }

    @Test func csvGainsWayStreetAndCategoryAsTrailingColumns() throws {
        let (input, out) = try Self.input()
        let lines = CSVExporter.export(input).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0].hasPrefix("timestamp,lat,lon,accuracy,speed,heading,altitude,"))
        #expect(lines[0].hasSuffix(",segment,roadType,wayId,street,osmCategory"))
        let columns = lines[0].split(separator: ",").count
        #expect(columns == 18)
        let rows = lines.dropFirst().filter { !$0.isEmpty }
        #expect(rows.count == input.fixes.count)
        var matched = 0
        for (i, row) in rows.enumerated() {
            let cells = row.split(separator: ",", omittingEmptySubsequences: false)
            #expect(cells.count == columns, "row \(i)")
            if let way = out.details.fixWays[i] {
                matched += 1
                #expect(cells[15] == Substring(String(way)))
                #expect(!cells[16].isEmpty)
            } else {
                #expect(cells[15].isEmpty)
            }
        }
        #expect(matched > rows.count / 2)
    }

    @Test func geoJSONHasOnePointPerPassedFeature() throws {
        let (input, out) = try Self.input()
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(GeoJSONExporter.export(input).utf8)) as? [String: Any])
        let features = try #require(obj["features"] as? [[String: Any]])
        let road = features.filter { ($0["properties"] as? [String: Any])?["kind"] as? String == "roadFeature" }
        #expect(road.count == out.details.passed.count)
        #expect(road.count > 10)
        let first = try #require(road.first)
        let coords = try #require((first["geometry"] as? [String: Any])?["coordinates"] as? [Double])
        #expect(coords.count == 2)
        #expect(coords[0] < -96 && coords[1] > 32) // [lon, lat]
        let props = try #require(first["properties"] as? [String: Any])
        #expect(props["type"] as? String != nil && props["wayId"] != nil && props["time"] as? String != nil)
    }

    @Test func jsonCarriesTheRoadsBlockAndThePassedFeatures() throws {
        let (input, out) = try Self.input()
        let obj = try #require(try JSONSerialization.jsonObject(with: JSONExporter.export(input)) as? [String: Any])
        let roads = try #require(obj["roads"] as? [String: Any])
        #expect((roads["counts"] as? [String: Any])?["signalSites"] as? Int == out.statistics.counts.signalSites)
        let passed = try #require(obj["passedFeatures"] as? [[String: Any]])
        #expect(passed.count == out.details.passed.count)
        let p = try #require(passed.first)
        for key in ["nodeId", "type", "time", "lat", "lon", "wayId", "street"] { #expect(p[key] != nil, "missing \(key)") }
        #expect((obj["roadDataAttribution"] as? String)?.contains("OpenStreetMap") == true)
    }

    @Test func tripsCSVGainsTheRoadCounts() throws {
        let (input, out) = try Self.input()
        let plain = TripRecord(startedAt: Date(), isRecording: false) // a 1.0 trip without road data
        let text = TripsSummaryCSV.export([(input.record, input.statistics), (plain, input.statistics)])
        let lines = text.split(separator: "\n").map(String.init)
        // The 1.1 road columns follow the 1.0 columns; only the 1.2 motion columns come after them.
        #expect(lines[0].hasSuffix(",note,signal_sites,stop_signs,all_way_stops,skewed_junctions,stops_at_signal,stops_at_stop_sign,road_coverage"
            + MotionSummaryColumns.header))
        let header = lines[0].split(separator: ",", omittingEmptySubsequences: false)
        let first = lines[1].split(separator: ",", omittingEmptySubsequences: false)
        let second = lines[2].split(separator: ",", omittingEmptySubsequences: false)
        #expect(first.count == header.count && second.count == header.count)
        let k = header.firstIndex(of: "signal_sites")!
        #expect(first[k] == Substring(String(out.statistics.counts.signalSites)))
        #expect(first[header.firstIndex(of: "stops_at_signal")!] == "1")
        #expect(second[k].isEmpty)
    }

    @Test func roadDetailsForOtherFixesAreNotUsed() throws {
        let (input, out) = try Self.input()
        let shorter = TripExportInput(record: input.record, fixes: Array(input.fixes.dropLast()), events: [], roads: out.details)
        #expect(shorter.roads == nil)
    }
}

struct CSVInjectionTests {
    @Test func freeTextThatLooksLikeAFormulaIsNeutralized() {
        #expect(CSVExporter.field("=HYPERLINK(\"http://x\")") == "\"'=HYPERLINK(\"\"http://x\"\")\"")
        #expect(CSVExporter.field("+1 Main") == "'+1 Main")
        #expect(CSVExporter.field("-Spur") == "'-Spur")
        #expect(CSVExporter.field("@cmd") == "'@cmd")
        #expect(CSVExporter.field("\tTab") == "'\tTab")
        #expect(CSVExporter.field("Main Street") == "Main Street")
        #expect(CSVExporter.field("Elm St, North") == "\"Elm St, North\"")
        #expect(CSVExporter.field(nil) == "")
    }
}
