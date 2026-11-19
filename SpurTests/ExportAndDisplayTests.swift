import Foundation
import Testing
@testable import Spur

/// Collects GPX structure through Foundation's XMLParser.
final class GPXProbe: NSObject, XMLParserDelegate {
    var trkpt = 0
    var trkseg = 0
    var wpt = 0
    var names: [String] = []
    var speeds: [String] = []
    private var text = ""
    private var element = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        element = name
        text = ""
        switch name {
        case "trkpt": trkpt += 1
        case "trkseg": trkseg += 1
        case "wpt": wpt += 1
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "name" { names.append(text) }
        if name == "spur:speed" { speeds.append(text) }
    }
}

struct ExportTests {
    static func input(events: [TripEvent] = [], title: String? = nil) -> TripExportInput {
        let a = Fixtures.northbound(speeds: Array(repeating: 12.5, count: 5))
        let b = Fixtures.shifted(a, byMs: 30_000)
        var record = TripRecord(startedAt: a[0].date, isRecording: false)
        record.endedAt = b.last!.date
        record.customTitle = title
        record.context.driverName = "Ana, \"Testfahrerin\""
        return TripExportInput(record: record, fixes: a + b, events: events)
    }

    @Test func csvHeaderAndValues() {
        var input = Self.input()
        input.fixes[0].isSimulatedBySoftware = true
        input.fixes[0].ellipsoidalAltitude = nil
        let csv = CSVExporter.export(input)
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Version 1.1 (SPEC 14.7) appends wayId, street and osmCategory; the 1.0 columns are unchanged.
        #expect(lines[0] == "timestamp,lat,lon,accuracy,speed,heading,altitude,altitudeAccuracy,ellipsoidalAltitude,speedAccuracy,headingAccuracy,simulated,accessory,segment,roadType,wayId,street,osmCategory")
        #expect(lines.count == 1 + 10 + 1) // header, 10 rows, trailing empty
        let f = input.fixes[0]
        // Without road data the three new fields are empty.
        #expect(lines[1] == "2026-11-11T18:00:00.000Z,\(f.latitude),\(f.longitude),4,12.5,0,150,3,,0.5,,true,,0,Stadt,,,")
        // Second segment after the 30 s gap.
        #expect(lines[6].hasSuffix(",1,Stadt,,,")) // 12.5 m/s = 45 km/h
        #expect(!csv.contains("e-"))
    }

    @Test func csvFieldEscaping() {
        #expect(CSVExporter.field("a,b") == "\"a,b\"")
        #expect(CSVExporter.field("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(CSVExporter.field("plain") == "plain")
        #expect(CSVExporter.field(nil) == "")
    }

    @Test func gpxIsWellFormedWithSegmentsAndWaypoints() throws {
        let event = TripEvent(id: UUID(), timestampMs: Fixtures.baseMs + 2000, latitude: 32.78, longitude: -96.8,
                              altitude: 151, tag: .construction, note: "Spur <links> & rechts")
        let input = Self.input(events: [event], title: "Test & <Fahrt> \"1\"")
        let gpx = GPXExporter.export(input)
        let parser = XMLParser(data: Data(gpx.utf8))
        let probe = GPXProbe()
        parser.delegate = probe
        parser.shouldProcessNamespaces = false
        #expect(parser.parse(), "\(parser.parserError.map(String.init(describing:)) ?? "")")
        #expect(probe.trkseg == 2)
        #expect(probe.trkpt == 10)
        #expect(probe.wpt == 1)
        #expect(probe.names.contains("Test & <Fahrt> \"1\""))
        #expect(probe.names.contains("Baustelle"))
        #expect(probe.speeds.count == 10 && probe.speeds[0] == "12.5")
        #expect(gpx.contains("<time>2026-11-11T18:00:00.000Z</time>"))
    }

    @Test func geoJSONParsesWithLonLatOrder() throws {
        let event = TripEvent(id: UUID(), timestampMs: Fixtures.baseMs, latitude: 32.78, longitude: -96.8,
                              altitude: nil, tag: .hazard, note: nil)
        var input = Self.input(events: [event])
        // GeoJSON heights are ellipsoidal (RFC 7946 section 4): set one, sea level altitude stays 150.
        for i in input.fixes.indices { input.fixes[i].ellipsoidalAltitude = 124.25 }
        let text = GeoJSONExporter.export(input)
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(obj["type"] as? String == "FeatureCollection")
        let features = try #require(obj["features"] as? [[String: Any]])
        #expect(features.count == 3) // two segments, one marker
        let geometry = try #require(features[0]["geometry"] as? [String: Any])
        #expect(geometry["type"] as? String == "LineString")
        let coords = try #require(geometry["coordinates"] as? [[Double]])
        #expect(coords.count == 5)
        try #require(coords[0].count == 3)
        #expect(coords[0][0] == input.fixes[0].longitude)
        #expect(coords[0][1] == input.fixes[0].latitude)
        #expect(coords[0][2] == 124.25)
        let point = try #require(features[2]["geometry"] as? [String: Any])
        #expect(point["type"] as? String == "Point")
        #expect(point["coordinates"] as? [Double] == [-96.8, 32.78])
        let props = try #require(features[0]["properties"] as? [String: Any])
        #expect(props["driver"] as? String == "Ana, \"Testfahrerin\"")
    }

    @Test func jsonExportRoundTripsTheRecord() throws {
        let input = Self.input()
        let data = try JSONExporter.export(input)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["format"] as? String == "spur-trip")
        let trip = try JSONSerialization.data(withJSONObject: try #require(obj["trip"]))
        #expect(try TripStore.decoder().decode(TripRecord.self, from: trip) == input.record)
        #expect((obj["gaps"] as? [Any])?.count == 1)
        let stats = try #require(obj["statistics"] as? [String: Any])
        #expect(stats["distance"] as? Double == input.statistics.distance)
    }

    @Test func tripsSummaryHasOneRowPerTrip() {
        let input = Self.input()
        let csv = TripsSummaryCSV.export([(input.record, input.statistics), (input.record, input.statistics)])
        let lines = csv.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("id,title,start,end,distance_m"))
        #expect(lines[1].contains("\"Ana, \"\"Testfahrerin\"\"\""))
    }

    @Test func fileStemIsAsciiAndSortable() {
        #expect(Self.input().fileStem == "spur-2026-11-11T180000Z")
    }
}

struct NumTests {
    @Test func isoTimestamps() {
        #expect(Num.iso(ms: 0) == "1970-01-01T00:00:00.000Z")
        #expect(Num.iso(ms: 1_731_312_902_250) == "2024-11-11T08:15:02.250Z")
        #expect(Num.iso(ms: -1) == "1969-12-31T23:59:59.999Z")
    }

    @Test func plainNumbersNeverUseExponents() {
        #expect(Num.plain(0.00001) == "0.00001")
        #expect(Num.plain(-96.797012345678) == "-96.797012345678")
        #expect(Num.plain(150) == "150")
        #expect(Num.plain(1e-7) == "0.0000001")
        #expect(Num.json(nil) == "null")
        #expect(Num.json(.nan) == "null")
        #expect(Num.csv(nil) == "")
    }
}

struct DisplayGeometryTests {
    static func line(_ n: Int) -> [LatLon] {
        (0..<n).map { LatLon(lat: 32 + Geo.latitudeDegrees(forMeters: Double($0) * 10), lon: -96) }
    }

    @Test func decimationRespectsBudgetAndKeepsEndpoints() {
        for n in [2001, 2500, 10_000, 54_321] {
            let pts = Self.line(n)
            let d = TrailGeometry.decimate(pts, budget: 2000)
            #expect(d.count <= 2000 && d.count >= 1000)
            #expect(d.first == pts.first && d.last == pts.last)
        }
        let small = Self.line(500)
        #expect(TrailGeometry.decimate(small, budget: 2000) == small)
    }

    @Test func decimationKeepsTheRecentTailAtFullResolution() {
        let pts = Self.line(20_000)
        let d = TrailGeometry.decimate(pts, budget: 2000, keepTail: 300)
        #expect(d.count <= 2000)
        #expect(Array(d.suffix(300)) == Array(pts.suffix(300)))
        #expect(d.first == pts.first)
    }

    @Test func chevronsEvery250MetersOverThreeKilometers() {
        let pts = Self.line(501) // 5 km due north
        let c = TrailGeometry.chevrons(pts)
        #expect(c.count == 12)
        #expect(c.allSatisfy { abs($0.bearing) < 1e-6 || abs($0.bearing - 360) < 1e-6 })
        // The newest chevron sits 250 m behind the end.
        let end = pts.last!
        let newest = c.last!.point
        #expect(approx(Geo.distance(lat1: newest.lat, lon1: newest.lon, lat2: end.lat, lon2: end.lon), 250, 1e-3))
        #expect(TrailGeometry.chevrons(pts, spacing: 100, lookback: 5000).count == 15)
        #expect(TrailGeometry.chevrons([pts[0]]).isEmpty)
    }

    @Test func previewStaysWithinBudgetAndRoundTrips() throws {
        let f = Fixtures.northbound(speeds: Array(repeating: 20, count: 5000))
        let preview = TrailGeometry.preview(f, config: .default, budget: 400)
        #expect(preview.count == 1)
        #expect(preview[0].count <= 400 && preview[0].first == LatLon(lat: f[0].latitude, lon: f[0].longitude))
        let data = try JSONEncoder().encode(preview)
        #expect(try JSONDecoder().decode([[LatLon]].self, from: data) == preview)
        #expect(String(decoding: try JSONEncoder().encode(LatLon(lat: 1.5, lon: -2)), as: UTF8.self) == "[1.5,-2]")
    }

    @Test func displayRunsSplitAtGapsAndJumps() {
        let a = Fixtures.northbound(speeds: Array(repeating: 20, count: 5))           // fixes 0...4
        let b = Fixtures.shifted(Fixtures.northbound(speeds: Array(repeating: 20, count: 5)), byMs: 20_000)  // 15 s gap
        // A teleport 3 km east one second after the last fix: 3000 m/s.
        var c = Fixtures.shifted(Fixtures.northbound(speeds: Array(repeating: 20, count: 5)), byMs: 25_000)
        for i in c.indices { c[i].longitude += 0.032 }
        var lone = Fixtures.shifted([a[0]], byMs: 60_000)[0] // a single fix after another gap
        lone.latitude += 0.01
        let runs = TrailGeometry.displayRuns(a + b + c + [lone], config: .default)
        #expect(runs == [Array(0...4), Array(5...9), Array(10...14)])
        // No gap, normal speed: one run.
        #expect(TrailGeometry.displayRuns(a, config: .default) == [Array(0...4)])
        // The preview has one line per run and none crosses a gap.
        #expect(TrailGeometry.preview(a + b + c, config: .default).count == 3)
    }

    @Test func headingFallsBackToBearing() {
        #expect(TrailGeometry.heading(course: 42, recent: []) == 42)
        let east = [LatLon(lat: 0, lon: 0), LatLon(lat: 0, lon: 0.001)]
        #expect(approx(TrailGeometry.heading(course: nil, recent: east), 90, 1e-6))
        #expect(TrailGeometry.heading(course: nil, recent: [LatLon(lat: 0, lon: 0)]) == nil)
    }

    @Test func geoBearingAndDestination() {
        let d = Geo.destination(lat: 32, lon: -96, bearing: 90, distance: 1000)
        #expect(approx(Geo.distance(lat1: 32, lon1: -96, lat2: d.lat, lon2: d.lon), 1000, 1e-6))
        #expect(approx(Geo.bearing(lat1: 0, lon1: 0, lat2: 1, lon2: 0), 0, 1e-9))
        #expect(approx(Geo.bearing(lat1: 0, lon1: 0, lat2: -1, lon2: 0), 180, 1e-9))
    }
}

struct UnitTests {
    @Test func conversions() {
        #expect(approx(UnitSystem.metric.speed(27.77777777777778), 100, 1e-9))
        #expect(approx(UnitSystem.imperial.speed(26.8224), 60, 1e-9))
        #expect(approx(UnitSystem.metric.distance(1500), 1.5))
        #expect(approx(UnitSystem.imperial.distance(1609.344), 1))
        #expect(approx(UnitSystem.imperial.elevation(0.3048), 1, 1e-12))
        #expect(UnitSystem.metric.speedUnit == "km/h" && UnitSystem.imperial.speedUnit == "mph")
    }

    @Test func germanDisplayFormatting() {
        #expect(Format.distance(1500, .metric) == "1,50")
        #expect(Format.distance(123_456, .metric) == "123")
        #expect(Format.speed(27.77777777777778, .metric) == "100")
        #expect(Format.clock(3725) == "1:02:05")
        #expect(Format.clock(65) == "1:05")
        #expect(Format.duration(3900) == "1 h 05 min")
        #expect(Format.duration(3780) == "1 h 03 min")
        #expect(Format.duration(844) == "14 min 04 s")
        #expect(Format.duration(30) == "30 s")
        #expect(Format.duration(0) == "0 s")
        #expect(Format.duration(59.9) == "59 s")
        #expect(Format.percent(0.256) == "26 %")
    }
}
