import CoreLocation
import XCTest

/// SPEC 18.4: the scenario finder in Planen on the Dallas pack.
final class ExploreTests: XCTestCase {
    @MainActor
    func testExploreFindsScenariosAndTheNearestUndriven() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-SpurTab", "plan"] + RealTripFlowTests.mapStyleArguments
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: 32.7767, longitude: -96.7970))
        app.launch()
        let explore = app.buttons["plan.explore"]
        XCTAssertTrue(explore.waitForExistence(timeout: 10), "no Entdecken")
        Thread.sleep(forTimeInterval: 3) // the GPS warm-up gives the origin
        explore.tap()
        let search = app.buttons["explore.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        let first = app.buttons["explore.result.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 60), "no scenario in downtown Dallas: \(app.staticTexts["explore.message"].exists ? app.staticTexts["explore.message"].label : "no message")")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "explore-results"
        shot.lifetime = .keepAlways
        add(shot)
        first.tap()
        XCTAssertTrue(app.buttons["plan.navigate"].waitForExistence(timeout: 10), "the result opens no card with Navigieren")
        let card = XCTAttachment(screenshot: app.screenshot())
        card.name = "explore-card"
        card.lifetime = .keepAlways
        add(card)
        app.buttons["Schließen"].tap()
        XCTAssertTrue(explore.waitForExistence(timeout: 5))
        explore.tap()
        app.buttons["explore.nearest"].tap()
        XCTAssertTrue(app.buttons["plan.navigate"].waitForExistence(timeout: 60), "no nearest undriven stretch")
    }
}

/// SPEC 18.5: a Rundkurs planned in Planen, its card, and the route on the live map.
final class DiscoveryRouteTests: XCTestCase {
    @MainActor
    func testPlanALoopAndShowItOnTheLiveMap() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-SpurTab", "plan"] + RealTripFlowTests.mapStyleArguments
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: 32.7767, longitude: -96.7970))
        app.launch()
        let explore = app.buttons["plan.explore"]
        XCTAssertTrue(explore.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 3)
        explore.tap()
        let plan = app.buttons["explore.plan"]
        XCTAssertTrue(plan.waitForExistence(timeout: 5))
        if !plan.isHittable { app.swipeUp() }
        plan.tap()
        let card = app.staticTexts["route.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 120), "no route card")
        XCTAssertTrue(card.label.contains("km neu"), card.label)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "route-card"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["route.show"].tap()
        let banner = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Entdeckerroute")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "the route is not on the live map")
        let live = XCTAttachment(screenshot: app.screenshot())
        live.name = "route-live"
        live.lifetime = .keepAlways
        add(live)

        // SPEC 18.6: a recording started with the route shown keeps the route on the map.
        let start = app.buttons["Start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        app.tap() // lets the interruption monitor handle a permission alert, if any
        XCTAssertTrue(app.buttons["Ereignis markieren"].waitForExistence(timeout: 15), "recording did not start")
        XCTAssertTrue(banner.exists, "the route left the map when the recording started")
        let recording = XCTAttachment(screenshot: app.screenshot())
        recording.name = "route-recording"
        recording.lifetime = .keepAlways
        add(recording)
        let stop = app.descendants(matching: .any)["Fahrt beenden"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).press(forDuration: 2.0)
        // Standing still in the simulator gives no fixes, so the stop discards the trip and Start returns.
        XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 20), "the recording did not stop")
    }
}

/// SPEC 18.8: a gap's suggested route, accepted, undone and rejected in the trip details.
final class GapFillUITests: XCTestCase {
    @MainActor
    func testAcceptUndoAndRejectAGapFill() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-SpurGapDemo", "YES", "-SpurOpenTrip", "gapdemo", "-SpurDetailScroll", "luecken"] + RealTripFlowTests.mapStyleArguments
        app.launch()
        let accept = app.buttons["gap.accept"]
        XCTAssertTrue(accept.waitForExistence(timeout: 60), "no suggestion for the demo trip's gap: \(app.staticTexts["gap.text"].exists ? app.staticTexts["gap.text"].label : "no gap row")")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "gap-suggestion"
        shot.lifetime = .keepAlways
        add(shot)
        accept.tap()
        XCTAssertTrue(app.buttons["gap.undo"].waitForExistence(timeout: 5), "no undo after accepting")
        let accepted = XCTAttachment(screenshot: app.screenshot())
        accepted.name = "gap-accepted"
        accepted.lifetime = .keepAlways
        add(accepted)
        // The overview with "Ergänzt" sits below the gap card.
        let metric = app.descendants(matching: .any)["gap.filledMetric"]
        for _ in 0..<3 where !metric.isHittable { app.swipeUp() }
        XCTAssertTrue(metric.waitForExistence(timeout: 5), "no Ergänzt metric")
        for _ in 0..<4 where !app.buttons["gap.undo"].isHittable { app.swipeDown() }
        app.buttons["gap.undo"].tap()
        XCTAssertTrue(app.buttons["gap.reject"].waitForExistence(timeout: 5), "undo does not bring the choice back")
        app.buttons["gap.reject"].tap()
        XCTAssertTrue(app.buttons["gap.undo"].waitForExistence(timeout: 5), "no way back after rejecting")
    }
}

/// SPEC 18.11: streets by name, the nearest undiscovered ones, and the way to the undriven part.
final class StreetSearchUITests: XCTestCase {
    @MainActor
    func testFindAStreetAndGoToItsUndrivenPart() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-SpurTab", "plan", "-SpurSeedDemo", "YES"] + RealTripFlowTests.mapStyleArguments
        app.launch()
        let field = app.textFields["plan.search"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        // An empty field lists the nearest undiscovered streets.
        let first = app.buttons["street.result.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 60), "no undiscovered streets nearby")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Unentdeckte Straßen in der Nähe")).firstMatch.exists, "no header for the nearby list")
        func shot(_ name: String) {
            let a = XCTAttachment(screenshot: app.screenshot())
            a.name = name
            a.lifetime = .keepAlways
            add(a)
        }
        shot("street-nearby")
        field.typeText("elm")
        let hit = app.buttons["street.result.0"]
        XCTAssertTrue(hit.waitForExistence(timeout: 10))
        XCTAssertTrue(hit.label.lowercased().contains("elm"), "first match: \(hit.label)")
        hit.tap()
        let card = app.staticTexts["street.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "no street card")
        XCTAssertTrue(card.label.contains("lang"), card.label)
        shot("street-card")
        app.buttons["street.go"].tap()
        XCTAssertTrue(app.staticTexts["plan.eta"].waitForExistence(timeout: 20), "the way there did not open the place card")
        shot("street-go")
    }
}
