import Foundation
import Testing
@testable import Spur

/// Regression tests for the findings of the first review panel.
struct ReviewFindingTests {
    // MARK: GeoJSON

    @Test func singleFixSegmentBecomesAPointAndNoLineStringHasFewerThanTwoPositions() throws {
        let a = Fixtures.northbound(speeds: Array(repeating: 10, count: 4))
        let lone = Fixtures.shifted([a[0]], byMs: 30_000)          // gap before and after
        let b = Fixtures.shifted(Fixtures.northbound(speeds: Array(repeating: 10, count: 3)), byMs: 60_000)
        let input = TripExportInput(record: TripRecord(startedAt: a[0].date, isRecording: false), fixes: a + lone + b, events: [])
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(GeoJSONExporter.export(input).utf8)) as? [String: Any])
        let features = try #require(obj["features"] as? [[String: Any]])
        let geometries = features.compactMap { $0["geometry"] as? [String: Any] }
        #expect(geometries.map { $0["type"] as? String } == ["LineString", "Point", "LineString"])
        for g in geometries where g["type"] as? String == "LineString" {
            #expect(((g["coordinates"] as? [[Double]])?.count ?? 0) >= 2)
        }
    }

    @Test func geoJSONHeightIsEllipsoidalNotSeaLevel() throws {
        var f = Fixtures.northbound(speeds: [10, 10])
        f[0].ellipsoidalAltitude = 123.5   // fixture altitude above sea level is 150
        var event = TripEvent(id: UUID(), timestampMs: f[0].timestampMs, latitude: 1, longitude: 2, altitude: 150, tag: .other, note: nil)
        event.ellipsoidalAltitude = 124
        let input = TripExportInput(record: TripRecord(startedAt: f[0].date, isRecording: false), fixes: f, events: [event])
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(GeoJSONExporter.export(input).utf8)) as? [String: Any])
        let features = try #require(obj["features"] as? [[String: Any]])
        let line = try #require((features[0]["geometry"] as? [String: Any])?["coordinates"] as? [[Double]])
        #expect(line[0] == [f[0].longitude, f[0].latitude, 123.5])
        #expect(line[1].count == 2) // no ellipsoidal height known: 2D position
        let point = try #require((features[1]["geometry"] as? [String: Any])?["coordinates"] as? [Double])
        #expect(point == [2, 1, 124])
    }

    // MARK: Road type hysteresis

    @Test func hysteresisRestartsAfterAGap() {
        // 110 km/h until k = 120, 30 km/h from k = 121 to 160: the slow candidate is pending from
        // k = 151. A 60 s gap follows; slow driving continues from k = 221. The new class must
        // hold 30 s in the new segment: Stadt from k = 251, not at the first fix after the gap.
        let first = (0...160).map { $0 <= 120 ? RoadTypeTests.kmh(110) : RoadTypeTests.kmh(30) }
        let a = Fixtures.northbound(speeds: first)
        let b = Fixtures.northbound(speeds: Array(repeating: RoadTypeTests.kmh(30), count: 80),
                                    startMs: Fixtures.baseMs + 221_000)
        let c = TripAnalyzer.analyze(fixes: a + b).roadClassPerFix
        #expect(c[160] == .autobahn)
        #expect(c[161] == .autobahn)   // k = 221, first fix after the gap
        #expect(c[190] == .autobahn)   // k = 250
        #expect(c[191] == .stadt)      // k = 251
    }

    // MARK: Units

    @Test func histogramAndLegendFollowTheUnitSetting() {
        // 8 m/s = 17.9 mph (bin 10), 14 m/s = 31.3 mph (bin 30).
        let track = Track(fixes: Fixtures.northbound(speeds: [8, 8, 8, 14, 14]))
        let mph = SpeedStats.histogram(track, unitsPerMps: UnitSystem.imperial.unitsPerMps, binWidth: 10)
        #expect(mph.map(\.index) == [0, 1, 2, 3])
        #expect(mph[1].seconds == 2 && mph[3].seconds == 2)
        #expect(TripDetailModel.legendLabels(.metric) == ["<30", "30", "50", "70", "90", "110+"])
        #expect(TripDetailModel.legendLabels(.imperial) == ["<19", "19", "31", "43", "56", "68+"])
    }

    @Test func wholePercentsAddUpToOneHundred() {
        #expect(Format.wholePercents([0.234, 0.306, 0.46]) == [23, 31, 46])
        #expect(Format.wholePercents([0.235, 0.31, 0.455]).reduce(0, +) == 100)
        #expect(Format.wholePercents([1, 1, 1]).reduce(0, +) == 100)
        #expect(Format.wholePercents([0, 0, 0]) == [0, 0, 0])
    }

    // MARK: Places

    @Test func theEndSampleAddsNoStreet() {
        let f = Fixtures.northbound(speeds: Array(repeating: 10, count: 101))
        let samples = [
            PlaceSample(timestampMs: f[0].timestampMs, latitude: 0, longitude: 0, kind: .start, locality: "Dallas", street: "Main St"),
            PlaceSample(timestampMs: f[100].timestampMs, latitude: 0, longitude: 0, kind: .end, locality: "Dallas", street: "Commerce St"),
        ]
        let p = PlacesSummary.compute(samples: samples, track: Track(fixes: f))
        #expect(p.streets.map(\.name) == ["Main St"])
        #expect(p.endPlace == "Dallas")
    }

    // MARK: Read-modify-write

    @Test func renameKeepsAnEndPlaceSavedMeanwhile() throws {
        let store = TripStore(root: Fixtures.tempDir())
        let fixes = Fixtures.northbound(speeds: Array(repeating: 10, count: 10))
        let r = TripLifecycle.finalized(TripRecord(startedAt: fixes[0].date, isRecording: false),
                                        contents: FixFile.Contents(fixes: fixes), config: .default)
        try store.create(r)
        let staleCopy = try store.load(r.id) // what the detail screen holds
        // The end place arrives after the detail opened.
        try store.update(r.id) {
            $0.places.append(PlaceSample(timestampMs: fixes[9].timestampMs, latitude: 0, longitude: 0, kind: .end, locality: "Irving"))
        }
        let model = AppModel(store: store, settings: Settings(defaults: UserDefaults(suiteName: "spur-tests-\(UUID().uuidString)")!))
        let saved = try #require(model.update(trip: r.id) { $0.customTitle = "Testfahrt" })
        #expect(saved.customTitle == "Testfahrt")
        #expect(saved.places.contains { $0.kind == .end && $0.locality == "Irving" })
        #expect(try store.load(r.id) == saved)
        #expect(staleCopy.places.isEmpty)
    }

    // MARK: Export

    @Test func aNewShareRemovesEarlierShareFolders() throws {
        let (store, records) = try ExportServiceTests.store(trips: 1)
        let temp = Fixtures.tempDir()
        let first = try ExportService.exportTrip(records[0].id, formats: [.csv], store: store, config: .default,
                                                 documents: Fixtures.tempDir(), temp: temp)
        let second = try ExportService.exportTrip(records[0].id, formats: [.csv], store: store, config: .default,
                                                  documents: Fixtures.tempDir(), temp: temp)
        #expect(!FileManager.default.fileExists(atPath: first[0].deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: second[0].path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.path).filter { $0.hasPrefix("share-") }.count == 1)
    }

    // MARK: Recovery split

    @Test func cleanUpLeavesTheResumedTripAlone() throws {
        let store = TripStore(root: Fixtures.tempDir())
        let resumed = try TripLifecycleTests.recordingTrip(in: store, lastFixAt: Date())
        let orphan = try TripLifecycleTests.recordingTrip(in: store, lastFixAt: Date())
        let result = TripLifecycle.cleanUp(store: store, except: resumed.id, config: .default)
        #expect(result.finalized == [orphan.id])
        #expect(try store.load(resumed.id).isRecording)
    }

    // MARK: Review 2

    @Test func aSingleUnusableFixDoesNotBlockAClassChange() {
        // 70 km/h until k = 120, then 30 km/h. One unusable fix every 20 s (k = 160, 180, 200).
        // The slow candidate holds from k = 150 or 151 (the even window at 150 sits at the
        // 50 km/h border), so Stadt replaces Land at k = 181, the first usable fix at least 30 s
        // later. Restarting the hold at every unusable fix would delay it to k = 231.
        var f = Fixtures.northbound(speeds: (0...300).map { $0 <= 120 ? RoadTypeTests.kmh(70) : RoadTypeTests.kmh(30) })
        for k in [160, 180, 200] { f[k].horizontalAccuracy = 60 }
        let c = TripAnalyzer.analyze(fixes: f).roadClassPerFix
        #expect(c[179] == .land)
        #expect(c[181] == .stadt)
    }

    @Test func aLongUnusableStretchStillRestartsTheHold() {
        // Same change, but k = 155...170 unusable (16 s without a usable fix): the hold restarts
        // at k = 171 and Stadt follows at k = 201.
        var f = Fixtures.northbound(speeds: (0...300).map { $0 <= 120 ? RoadTypeTests.kmh(70) : RoadTypeTests.kmh(30) })
        for k in 155...170 { f[k].horizontalAccuracy = 60 }
        let c = TripAnalyzer.analyze(fixes: f).roadClassPerFix
        #expect(c[200] == .land)
        #expect(c[201] == .stadt)
    }

    @Test func drivenLayerKeyChangesWhenAFinishedTripGetsItsPreview() {
        var r = TripRecord(startedAt: Date(), isRecording: false)
        let before = LiveMapView.drivenKey([r])
        r.preview = [[LatLon(lat: 1, lon: 2), LatLon(lat: 1.001, lon: 2)]]
        #expect(LiveMapView.drivenKey([r]) != before)
    }

    @Test func detailMapFramesOnlyWhatIsDrawn() async throws {
        let store = TripStore(root: Fixtures.tempDir())
        var fixes = Fixtures.northbound(speeds: Array(repeating: 10, count: 40)) // 390 m
        fixes[20].latitude += 0.2 // one multipath fix 22 km away, never drawn
        let r = TripLifecycle.finalized(TripRecord(startedAt: fixes[0].date, isRecording: false),
                                        contents: FixFile.Contents(fixes: fixes), config: .default)
        try store.create(r)
        let w = try store.openWriter(r.id)
        for f in fixes { try w.append(f) }
        w.close()
        let model = TripDetailModel(record: r)
        await model.load(store: store, config: .default, units: .metric)
        let span = try #require(model.bounds?.span.latitudeDelta)
        #expect(span < 0.02)
    }
}
