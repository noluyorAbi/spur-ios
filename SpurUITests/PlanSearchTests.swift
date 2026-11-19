import CoreLocation
import XCTest

/// SPEC 18.3: search a place, its card with the driving time, the route on the live map.
final class PlanSearchTests: XCTestCase {
    @MainActor
    func testSearchPlaceCardAndRouteInSpur() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-SpurTab", "plan"] + RealTripFlowTests.mapStyleArguments
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: 32.7767, longitude: -96.7970))
        app.launch()
        let field = app.textFields["plan.search"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no search field on Planen")
        field.tap()
        field.typeText("Dallas Museum of Art\n")
        let eta = app.staticTexts["plan.eta"]
        if !eta.waitForExistence(timeout: 15) {
            // Several results: the first chip opens the card.
            let chip = app.scrollViews.buttons.firstMatch
            XCTAssertTrue(chip.waitForExistence(timeout: 5), "no result")
            chip.tap()
        }
        XCTAssertTrue(eta.waitForExistence(timeout: 10), "no place card")
        let computed = expectation(for: NSPredicate(format: "label CONTAINS %@", "km"), evaluatedWith: eta)
        XCTAssertEqual(XCTWaiter.wait(for: [computed], timeout: 20), .completed, "no driving time: \(eta.label)")
        XCTAssertTrue(app.buttons["plan.navigate"].exists, "no Navigieren")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "place-card"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["plan.showRoute"].tap()
        app.tabBars.buttons["Fahrt"].tap()
        let banner = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Route nach")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 5), "the route is not on the Fahrt tab")
        let live = XCTAttachment(screenshot: app.screenshot())
        live.name = "route-on-live"
        live.lifetime = .keepAlways
        add(live)
    }
}
