import CoreLocation
import XCTest

/// Drives the real UI like the passenger does: Start, a simulated drive, hold to stop, the stop
/// summary, the trip detail, the export of that recorded trip, the history totals, the all-trips
/// ZIP and the "bereits gefahren" layer. `scripts/ui-flow.sh` runs it and then checks the files
/// it produced in the app container.
final class RealTripFlowTests: XCTestCase {
    static let origin = CLLocationCoordinate2D(latitude: 32.8000, longitude: -96.8000)

    /// `SPUR_MAP_STYLE=light|dark` (passed by scripts/ui-flow.sh as TEST_RUNNER_SPUR_MAP_STYLE) runs
    /// the flow in that Kartenstil (SPEC 18.1).
    static var mapStyleArguments: [String] {
        ProcessInfo.processInfo.environment["SPUR_MAP_STYLE"].flatMap { $0.isEmpty ? nil : ["-settings.mapStyle", $0] } ?? []
    }

    @MainActor
    func testStartHoldToStopHistoryDrivenLayerExportAndZip() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-SpurSeedDemo", "YES", "-SpurTab", "live", "-SpurSynthMotion", "YES"] + Self.mapStyleArguments
        addUIInterruptionMonitor(withDescription: "Standort") { alert in
            for label in ["Beim Verwenden der App erlauben", "Allow While Using App", "Einmal erlauben", "Allow Once"]
            where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: Self.origin.latitude, longitude: Self.origin.longitude))
        app.launch()

        // The driven layer shows the four synthetic demo trips.
        let layer = app.buttons["layer.driven"]
        XCTAssertTrue(layer.waitForExistence(timeout: 15))
        try waitFor(layer, value: "4 frühere Fahrten")

        // Start: the real button.
        let start = app.buttons["Start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        app.tap() // lets the interruption monitor handle a permission alert, if any
        XCTAssertTrue(app.buttons["Ereignis markieren"].waitForExistence(timeout: 15), "recording did not start")

        // Drive north, speeding up and slowing down by 2 m/s² every 5 s between 8 and 18 m/s, so
        // the synthetic motion sensor has something to align on (SPEC 17.6).
        var lat = Self.origin.latitude
        var speed = 10.0
        var second = 0
        func drive(_ seconds: Int) {
            for _ in 0..<seconds {
                second += 1
                speed = max(8, min(18, speed + ((second / 5) % 2 == 0 ? 2 : -2)))
                lat += speed / 111_195
                XCUIDevice.shared.location = XCUILocation(location: CLLocation(
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: Self.origin.longitude),
                    altitude: 150, horizontalAccuracy: 5, verticalAccuracy: 3, course: 0, speed: speed, timestamp: Date()
                ))
                Thread.sleep(forTimeInterval: 1)
            }
        }
        drive(12)

        // SPEC 18.9: Pause and Fortsetzen. The banner says nothing is recorded; standing still,
        // nothing is driven during the pause, and Fortsetzen brings the Pause symbol back.
        let pause = app.buttons["trip.pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "no Pause button while recording")
        XCTAssertEqual(pause.label, "Fahrt pausieren")
        pause.tap()
        XCTAssertTrue(app.staticTexts["Pausiert, es wird nichts aufgezeichnet"].waitForExistence(timeout: 5), "no pause banner")
        Thread.sleep(forTimeInterval: 2)
        attach(app, "paused")
        XCTAssertEqual(pause.label, "Fahrt fortsetzen")
        pause.tap()
        let resumed = expectation(for: NSPredicate(format: "label == %@", "Fahrt pausieren"), evaluatedWith: pause)
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 5), .completed, "Fortsetzen did not end the pause")
        drive(3)

        // SPEC 17.1: the live details panel, from its handle, before the mount is aligned: the size
        // of the acceleration only, no sign.
        let handle = app.buttons["live.details.handle"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5), "no Live-Details handle while recording")
        handle.tap()
        XCTAssertTrue(app.descendants(matching: .any)["live.gcircle"].waitForExistence(timeout: 10), "panel did not open")
        Thread.sleep(forTimeInterval: 2)
        attach(app, "panel-unaligned")
        drive(50)
        attach(app, "panel-medium")
        // The large height: every section of the running trip's details.
        app.buttons["live.details.size"].tap()
        XCTAssertTrue(app.staticTexts["Übersicht"].waitForExistence(timeout: 10), "large panel shows no Übersicht")
        Thread.sleep(forTimeInterval: 1)
        attach(app, "panel-large")
        app.buttons["live.details.close"].tap()
        XCTAssertTrue(handle.waitForExistence(timeout: 5), "panel did not close")

        // SPEC 17.8: the running trip opens its live details from the history.
        app.tabBars.buttons["Historie"].tap()
        let running = app.buttons["history.running"]
        XCTAssertTrue(running.waitForExistence(timeout: 10), "no running trip in the history")
        running.tap()
        XCTAssertTrue(app.staticTexts["Fahrdynamik live"].waitForExistence(timeout: 10), "running trip details did not open")
        drive(3)
        attach(app, "running-details")
        app.tabBars.buttons["Fahrt"].tap()
        drive(3)
        attach(app, "recording")

        let stop = app.descendants(matching: .any)["Fahrt beenden"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        let ring = stop.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5))

        // Accidental-stop guard: a short press (0.4 s, below the 1.2 s hold) must not stop.
        let clock = app.descendants(matching: .any)["trip.duration"]
        XCTAssertTrue(clock.waitForExistence(timeout: 5))
        let elapsedBefore = clock.label
        ring.press(forDuration: 0.4)
        // A press that is too short says how to stop instead of doing nothing visible.
        XCTAssertTrue(app.staticTexts["Zum Beenden gedrückt halten"].waitForExistence(timeout: 2), "a short press on the stop ring gave no hint")
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertTrue(stop.exists, "the stop control vanished after a short press")
        XCTAssertFalse(app.buttons["Fahrt ansehen"].exists, "a short press opened the stop summary")
        XCTAssertNotEqual(clock.label, elapsedBefore, "the elapsed time stopped counting: \(clock.label)")
        attach(app, "short-press")

        // Hold to stop: press the ring for 2 s.
        ring.press(forDuration: 2.0)

        // The stop summary, then the detail of the recorded trip.
        let open = app.buttons["Fahrt ansehen"]
        XCTAssertTrue(open.waitForExistence(timeout: 20), "no stop summary")
        attach(app, "summary")
        open.tap()
        // The running trip's details, still open in the history, are now the finished trip's (SPEC
        // 17.8): the export below is only offered for a finished trip.
        XCTAssertTrue(app.staticTexts["Übersicht"].waitForExistence(timeout: 15), "detail did not open")
        attach(app, "detail")

        // Export this trip: all four files.
        let actions = app.buttons["Aktionen"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        actions.tap()
        let all4 = app.buttons["Alle vier Dateien"]
        XCTAssertTrue(all4.waitForExistence(timeout: 5))
        all4.tap()
        try dismissShareSheet(app)

        // Back to the history: five trips in the totals.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let totals = app.descendants(matching: .any)["totals.trips"]
        XCTAssertTrue(totals.waitForExistence(timeout: 10))
        XCTAssertTrue(totals.label.contains("5"), "history totals: \(totals.label)")
        attach(app, "history")

        // Export all trips as ZIP.
        let zip = app.buttons["Alle Fahrten exportieren"]
        XCTAssertTrue(zip.waitForExistence(timeout: 5))
        zip.tap()
        try dismissShareSheet(app)

        // The driven layer now includes the recorded trip.
        app.tabBars.buttons["Fahrt"].tap()
        try waitFor(layer, value: "5 frühere Fahrten")
        attach(app, "driven-layer")
    }

    @MainActor
    private func waitFor(_ element: XCUIElement, value: String, timeout: TimeInterval = 15) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (element.value as? String) == value { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("\(element.identifier) value is \(String(describing: element.value)), expected \(value)")
    }

    /// The share sheet appears once the export is written; close it again.
    @MainActor
    private func dismissShareSheet(_ app: XCUIApplication) throws {
        let candidates = [app.buttons["Schließen"], app.buttons["Close"], app.navigationBars.buttons["Schließen"]]
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            // A frame first: while the sheet presents, asking a zero-frame button for hittability
            // raises instead of answering false.
            if let close = candidates.first(where: { $0.exists && !$0.frame.isEmpty && $0.isHittable }) {
                attach(app, "share-sheet")
                close.tap()
                Thread.sleep(forTimeInterval: 1)
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        attach(app, "share-sheet-missing")
        XCTFail("share sheet did not appear")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
