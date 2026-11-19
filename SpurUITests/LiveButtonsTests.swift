import XCTest

/// The round map buttons on the live view must react on their whole 48 pt circle, not only on the
/// small glyph in the middle (owner report 2026-11-11: "sometimes does not register").
final class LiveButtonsTests: XCTestCase {
    /// Points inside the 48 pt circle but off the 17 pt glyph: 15 pt from the center.
    static let offGlyph: [CGVector] = [
        CGVector(dx: 15, dy: 0), CGVector(dx: -15, dy: 0), CGVector(dx: 0, dy: -15), CGVector(dx: 0, dy: 15),
    ]

    @MainActor
    func testMapButtonsReactOnTheirWholeCircle() throws {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ["-SpurTab", "live"] + RealTripFlowTests.mapStyleArguments
        app.launch()

        for id in ["layer.roads", "layer.driven"] {
            let button = app.buttons[id]
            XCTAssertTrue(button.waitForExistence(timeout: 15), "\(id) missing")
            for offset in Self.offGlyph {
                let before = button.value as? String
                button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(offset).tap()
                let changed = expectation(for: NSPredicate(format: "value != %@", before ?? ""), evaluatedWith: button)
                let result = XCTWaiter.wait(for: [changed], timeout: 2)
                XCTAssertEqual(result, .completed, "\(id): a tap \(offset) pt from the center (off the glyph, inside the circle) did nothing")
            }
            XCTAssertGreaterThanOrEqual(button.frame.width, 44, "\(id) is smaller than a touch target")
        }

        // The map between the HUD parts still takes a drag (the HUD's glass container passes it
        // through): panning stops following, so "Zentrieren" appears, and it reacts like the others.
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
        from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.30)))
        let recenter = app.buttons["Zentrieren"]
        XCTAssertTrue(recenter.waitForExistence(timeout: 5), "a drag on the map did not reach the map")
        recenter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 15, dy: 0)).tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: recenter)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 3), .completed, "Zentrieren did not react off its glyph")

        // SPEC 18.2b and 18.7: the layer menu switches the map type and the coverage mode once,
        // and back, so the next run starts from Standard and Richtung.
        let layers = app.buttons["layer.mapType"]
        XCTAssertTrue(layers.waitForExistence(timeout: 5), "layer menu missing")
        func choose(_ item: String) {
            layers.tap()
            let entry = app.buttons[item]
            XCTAssertTrue(entry.waitForExistence(timeout: 3), "\(item) missing in the layer menu")
            entry.tap()
        }
        choose("Satellit")
        choose("Häufigkeit")
        XCTAssertEqual(layers.value as? String, "Satellit, Abdeckung Häufigkeit")
        choose("Standard")
        choose("Richtung")
        XCTAssertEqual(layers.value as? String, "Standard, Abdeckung Richtung")

        // SPEC 18.2 and 18.6: traffic on and off again.
        let traffic = app.buttons["layer.traffic"]
        XCTAssertTrue(traffic.waitForExistence(timeout: 5), "traffic button missing")
        traffic.tap()
        XCTAssertTrue((traffic.value as? String)?.hasPrefix("an") == true, "traffic did not switch on: \(String(describing: traffic.value))")
        traffic.tap()
        XCTAssertEqual(traffic.value as? String, "aus", "traffic did not switch off")
        // Let the setting reach disk before the app is terminated, so the next tests start without traffic.
        Thread.sleep(forTimeInterval: 1.5)
    }
}
