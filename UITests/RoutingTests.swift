import XCTest

/// H-011: a tapped notification opens what it announces. `-route kind/id[/bot]` is the
/// app's Debug hook that acts as a tapped notification; the ids come from the demo
/// (scripts/ui-tests.sh passes them).
final class RoutingTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testDecisionNotificationOpensDecisionDetail() throws {
        let id = try XCTUnwrap(DemoApp.decisionId, "No DEMO_DECISION_ID: run scripts/ui-tests.sh")
        let app = try DemoApp.launch(["-route", "decision/\(id)"])
        allowSystemAlerts()
        waitFor(app.navigationBars["Decision"])
        waitFor(app.staticTexts["Which accent colour for the App Store screenshots?"])
        XCTAssertTrue(app.tabBars.buttons["Decisions"].isSelected)
        screenshot("QA-002-route-decision")
    }

    func testWaitingNotificationOpensChat() throws {
        let bot = try XCTUnwrap(DemoApp.botId, "No DEMO_BOT_ID: run scripts/ui-tests.sh")
        let app = try DemoApp.launch(["-route", "waiting/\(bot)"])
        allowSystemAlerts()
        let chat = waitFor(app.buttons["Chat"])
        XCTAssertTrue(chat.isSelected, "The bot opened on another pane")
        XCTAssertTrue(app.tabBars.buttons["Bots"].isSelected)
        waitFor(app.staticTexts["iOS Dev"])
        waitFor(app.textFields["Message iOS Dev"].exists ? app.textFields["Message iOS Dev"] : app.textViews["Message iOS Dev"])
        screenshot("QA-002-route-waiting")
    }
}
