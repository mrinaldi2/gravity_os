import XCTest

/// H-248: "▲ Waiting for you" on a release, from a stubbed release (Debug -releaseStub), no daemon.
final class H248Tests: XCTestCase {
    private static let release = #"{"release":{"id":"rel-qa","name":"0.17.5","display_version":"0.17.5","status":"approved","version":3,"work_item_id":"H-247","owner_blockers":[{"kind":"run","id":"a-1","title":"Clear the stale build cache","item_id":"H-242","bot":null,"computer":"mac","created_at":"2026-10-08T08:00:00Z"},{"kind":"decision","id":"d-2","title":"Which accent colour?","item_id":"H-241","bot":null,"computer":null,"created_at":"2026-10-08T10:00:00Z"},{"kind":"question","id":"c-9","title":"Ship the notes as they are?","item_id":"H-240","bot":null,"computer":null,"created_at":"2026-10-08T11:00:00Z"},{"kind":"decision","id":"d-3","title":"Hold 0.17.5 for the fix?","item_id":"H-244","bot":null,"computer":null,"created_at":"2026-10-08T12:00:00Z"}]}}"#

    override func setUp() { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-gravHost", "127.0.0.1", "-gravPort", "41209", "-lensPort", "41208",
                               "-gravToken", "none", "-noNotificationPrompt", "YES", "-releaseStub", Self.release]
        app.launch()
        return app
    }

    func testTheSectionShowsAndADecisionOpens() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["▲ Waiting for you · 4"].waitForExistence(timeout: 20), "No Waiting for you section")
        XCTAssertTrue(app.staticTexts["Run it on mac, in The Hermes app."].exists, "the Run card says where to run it")
        XCTAssertTrue(app.buttons["+1 more"].exists, "more than 3: +n more")
        screenshot("H-248-waiting-for-you")
        app.buttons.containing(NSPredicate(format: "label CONTAINS 'Decide: Which accent colour?'")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Decision"].waitForExistence(timeout: 10), "Answer did not open the decision")
    }
}
