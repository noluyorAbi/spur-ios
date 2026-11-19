import Foundation
import Testing
@testable import Spur

/// SPEC 18.9: exports mark the pause spans; an unfinished pause is not exported.
struct PauseExportTests {
    @Test func gpxAndGeoJSONMarkEachFinishedPause() {
        let fixes = Fixtures.northbound(speeds: Array(repeating: 12, count: 40))
        var record = TripRecord(startedAt: fixes[0].date, isRecording: false)
        let t0 = fixes[10].date, t1 = fixes[30].date
        record.pauses = [
            TripPause(start: t0.addingTimeInterval(0.4), end: t0.addingTimeInterval(120), kind: .manual, evidence: nil),
            TripPause(start: t1, end: t1.addingTimeInterval(400), kind: .auto, evidence: "Motor aus"),
            TripPause(start: t1.addingTimeInterval(500), end: nil, kind: .manual, evidence: nil),
        ]
        let input = TripExportInput(record: record, fixes: fixes, events: [])
        #expect(input.pauseMarks.count == 2)
        #expect(input.pauseMarks[0].at == fixes[10], "placed at the last fix before the pause")
        let gpx = GPXExporter.export(input)
        #expect(gpx.contains("<type>pause.manual</type>") && gpx.contains("<type>pause.auto</type>"))
        #expect(gpx.components(separatedBy: "<name>Pause</name>").count - 1 == 2)
        #expect(gpx.contains("Motor aus"))
        let geo = GeoJSONExporter.export(input)
        #expect(geo.contains("\"kind\":\"pause\"") && geo.contains("\"pauseKind\":\"auto\"") && geo.contains("\"durationS\":400"))
    }
}
