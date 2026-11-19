import CoreLocation
import XCTest

/// SPEC 18.9: an automatic pause on a simulated car-park break. The stop stands off the road
/// (`-SpurSynthPlace offRoad`), and the break is 30 s instead of minutes (`-SpurAutoPauseMinutes`);
/// the minute settings and the never-pause cases are unit tests.
final class AutoPauseUITests: XCTestCase {
    static let origin = CLLocationCoordinate2D(latitude: 32.7767, longitude: -96.7970)

    @MainActor
    func testABreakPausesAndDrivingOnResumes() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-SpurSynthPlace", "offRoad", "-SpurAutoPauseMinutes", "0.5"] + RealTripFlowTests.mapStyleArguments
        var lat = Self.origin.latitude
        func fix(_ speed: Double) {
            lat += max(speed, 0.000_01 * 111_195) / 111_195 // standing: a centimetre of jitter so every fix arrives
            XCUIDevice.shared.location = XCUILocation(location: CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: Self.origin.longitude),
                altitude: 150, horizontalAccuracy: 5, verticalAccuracy: 3, course: 0, speed: speed, timestamp: Date()))
            Thread.sleep(forTimeInterval: 1)
        }
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: lat, longitude: Self.origin.longitude))
        app.launch()
        let start = app.buttons["Start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        start.tap()
        app.tap() // lets the interruption monitor handle a permission alert, if any
        XCTAssertTrue(app.buttons["Ereignis markieren"].waitForExistence(timeout: 15), "recording did not start")
        for _ in 0..<15 { fix(12) }
        let banner = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Automatisch pausiert")).firstMatch
        // The first standing fix starts the stop; the break counts by the fixes' clock.
        let stopped = Date()
        while !banner.exists && Date().timeIntervalSince(stopped) < 90 { fix(0) }
        let stood = Date().timeIntervalSince(stopped)
        XCTAssertTrue(banner.exists, "no automatic pause after \(Int(stood)) s standing")
        XCTAssertGreaterThanOrEqual(stood, 30, "paused before the break was long enough")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "auto-paused"
        shot.lifetime = .keepAlways
        add(shot)
        var drove = 0
        while banner.exists && drove < 40 { fix(12); drove += 1 }
        XCTAssertFalse(banner.exists, "driving on did not resume the trip after \(drove) s")
        let stop = app.descendants(matching: .any)["Fahrt beenden"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).press(forDuration: 2.0)
        XCTAssertTrue(app.buttons["Fahrt ansehen"].waitForExistence(timeout: 20), "the recording did not stop")
    }
}
