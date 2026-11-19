import CoreLocation
import XCTest

/// SPEC 16.2 on the real UI: driving the downtown fixture's North Ervay Street (30 mph), the sign
/// appears beside the speed without growing the card, driving too fast marks it "darüber", slowing
/// down clears that, and when the fixes stop the sign goes.
/// `scripts/replay-case6.sh` runs it with the fixture and the route in the environment.
final class SpeedLimitSignTests: XCTestCase {
    @MainActor
    func testTheLimitSignAppearsOnATaggedStreetAndTheCardKeepsItsHeight() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        let fixture = try XCTUnwrap(env["SPUR_ROAD_FIXTURE"], "the script passes the fixture's absolute path")
        let route = try XCTUnwrap(env["SPUR_LIMIT_ROUTE"], "the script passes the route: lat,lon,course,speed;...")
        let points = route.split(separator: ";").map { $0.split(separator: ",").compactMap { Double($0) } }.filter { $0.count == 4 }
        XCTAssertGreaterThan(points.count, 20)
        let app = XCUIApplication()
        app.launchArguments = ["-SpurRoadFixture", fixture, "-SpurTab", "live"]
        addUIInterruptionMonitor(withDescription: "Standort") { alert in
            for label in ["Beim Verwenden der App erlauben", "Allow While Using App", "Einmal erlauben", "Allow Once"]
            where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        func move(to p: [Double]) {
            XCUIDevice.shared.location = XCUILocation(location: CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: p[0], longitude: p[1]), altitude: 150, horizontalAccuracy: 5,
                verticalAccuracy: 3, course: p[2], courseAccuracy: 5, speed: p[3], speedAccuracy: 0.5, timestamp: Date()))
        }
        move(to: points[0])
        app.launch()
        let start = app.buttons["Start"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        start.tap()
        app.tap()
        XCTAssertTrue(app.buttons["Ereignis markieren"].waitForExistence(timeout: 15), "recording did not start")

        let card = app.descendants(matching: .any)["live.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let sign = app.descendants(matching: .any)["live.speedLimit"]
        XCTAssertFalse(sign.exists, "a sign before any road was matched")
        // The card height right before the sign appears and right after: the second text line
        // ("Ø ... in Fahrt") comes with movement and is not the sign's doing.
        var heightBefore = card.frame.height
        var heightWithSign: CGFloat?
        var labels: [String] = []
        var attachedOver = false
        for p in points {
            move(to: p)
            Thread.sleep(forTimeInterval: 1)
            if !sign.exists, heightWithSign == nil { heightBefore = card.frame.height }
            if sign.exists {
                let label = sign.label
                if labels.last != label { labels.append(label) }
                if heightWithSign == nil {
                    heightWithSign = card.frame.height
                    attach(app, "speed-limit")
                }
                if label.contains("darüber"), !attachedOver {
                    attachedOver = true
                    attach(app, "speed-limit-over")
                }
            }
        }
        // No more fixes (as in a tunnel): the sign is taken down after 5 s.
        Thread.sleep(forTimeInterval: 8)
        let goneAfterStop = !sign.exists
        print("SPEED LIMIT labels: \(labels), card height \(heightBefore) before, \(heightWithSign ?? -1) with the sign, gone 8 s after the last fix: \(goneAfterStop)")
        XCTAssertTrue(labels.contains("Tempolimit 30 mph laut OpenStreetMap"), "the 30 mph sign never appeared: \(labels)")
        XCTAssertTrue(labels.contains { $0.hasPrefix("Tempolimit 30 mph laut OpenStreetMap, ") && $0.hasSuffix(" mph darüber") },
                      "driving too fast never marked the sign: \(labels)")
        XCTAssertEqual(Double(heightWithSign ?? -1), Double(heightBefore), accuracy: 0.5, "the card grew with the sign")
        if let firstOver = labels.firstIndex(where: { $0.contains("darüber") }) {
            XCTAssertTrue(labels[(firstOver + 1)...].contains("Tempolimit 30 mph laut OpenStreetMap"), "the red state never cleared: \(labels)")
        }
        XCTAssertTrue(goneAfterStop, "the sign stayed without fixes")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
