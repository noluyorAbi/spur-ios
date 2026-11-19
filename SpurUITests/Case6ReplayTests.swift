import XCTest

/// SPEC 14.8: the parent's case 6 (downtown grid, 60 s at a red light) through the real engine.
/// `scripts/replay-case6.sh` runs this test with the downtown fixture as the app's road pack (its
/// absolute path in `SPUR_ROAD_FIXTURE`; the simulator reads the Mac's files) and drives the route with `simctl location start` once Start was pressed. The test presses
/// Start, waits until the trip has passed the last signal of the route, holds the stop ring and
/// checks the stop summary; the script then checks the stored trip against the oracle.
final class Case6ReplayTests: XCTestCase {
    @MainActor
    func testReplayCase6StartAndHoldToStop() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        let targetKm = Double(env["SPUR_REPLAY_TARGET_KM"] ?? "") ?? 0.95
        let app = XCUIApplication()
        let fixture = try XCTUnwrap(env["SPUR_ROAD_FIXTURE"], "the script passes the fixture's absolute path")
        app.launchArguments = ["-SpurRoadFixture", fixture, "-SpurTab", "live", "-SpurSynthMotion", "YES"]
        addUIInterruptionMonitor(withDescription: "Standort") { alert in
            for label in ["Beim Verwenden der App erlauben", "Allow While Using App", "Einmal erlauben", "Allow Once"]
            where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()

        let start = app.buttons["Start"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        start.tap()
        app.tap()
        XCTAssertTrue(app.buttons["Ereignis markieren"].waitForExistence(timeout: 15), "recording did not start")

        // The script drives now. Wait until the trip distance passed the last signal of the route.
        let distance = app.descendants(matching: .any)["live.distance"]
        XCTAssertTrue(distance.waitForExistence(timeout: 10))
        var km = 0.0
        var shotAtLight = false
        let deadline = Date().addingTimeInterval(420)
        while Date() < deadline {
            km = Self.kilometers(distance.label)
            // At the red light (the car stands about 0.3 km into the route): the POI layer and counters.
            if !shotAtLight && km > 0.28 {
                Thread.sleep(forTimeInterval: 8)
                attach(app, "replay-live")
                shotAtLight = true
            }
            if km >= targetKm { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertGreaterThanOrEqual(km, targetKm, "the drive did not reach \(targetKm) km: \(distance.label)")
        attach(app, "replay-before-stop")

        let stop = app.descendants(matching: .any)["Fahrt beenden"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).press(forDuration: 2.0)
        let open = app.buttons["Fahrt ansehen"]
        XCTAssertTrue(open.waitForExistence(timeout: 20), "no stop summary")
        attach(app, "replay-summary")
        open.tap()
        XCTAssertTrue(app.staticTexts["Übersicht"].waitForExistence(timeout: 15), "detail did not open")
        // Give the road analysis time to land in the stored trip before the app goes away.
        Thread.sleep(forTimeInterval: 12)
        attach(app, "replay-detail")
        // The road section of the detail.
        let coverage = app.descendants(matching: .any)["roads.coverage"]
        for _ in 0..<10 where !(coverage.exists && coverage.isHittable) {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(coverage.exists, "no road section in the detail")
        app.swipeUp(velocity: 300)
        Thread.sleep(forTimeInterval: 1)
        attach(app, "replay-roads")
    }

    /// "Strecke, 0,95 km" or "0,95 km" to 0.95.
    static func kilometers(_ label: String) -> Double {
        let pattern = try! NSRegularExpression(pattern: "([0-9]+(?:,[0-9]+)?)")
        let ns = label as NSString
        let matches = pattern.matches(in: label, range: NSRange(location: 0, length: ns.length))
        guard let m = matches.first else { return 0 }
        return Double(ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
