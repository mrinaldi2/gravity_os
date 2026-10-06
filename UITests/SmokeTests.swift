import XCTest

/// The main flows against the demo world: launch, what needs you, a bot's chat,
/// answering a decision, and the link sheet. Each test starts the app fresh.
/// Navigation follows H-134: Projects · Needs you · Chat · Settings.
final class SmokeTests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = try DemoApp.launch()
        allowSystemAlerts()
    }

    func testLaunchShowsProjects() {
        waitFor(app.navigationBars["Projects"])
        for tab in ["Projects", "Needs you", "Chat", "Settings"] {
            XCTAssertTrue(app.tabBars.buttons[tab].exists, "Tab \(tab)")
        }
        XCTAssertEqual(app.tabBars.buttons.count, 4, "Only the four H-134 tabs")
        waitFor(app.projectCard("Aurora Notes"))
    }

    func testNeedsYouShowsWhatNeedsYou() throws {
        try DemoControl.ensurePermissionPrompts()
        app.tab("Needs you")
        // The demo's three permission prompts, as rows here and as cards in Decisions.
        waitFor(app.needsRow("Backend Dev wants to run Bash"))
        waitFor(app.needsRow("iOS Dev wants to run Write"))
        waitFor(app.needsRow("Web Dev wants to run WebFetch"))
        screenshot("QA-004-smoke-needs-you")
        app.openDecisions()
        waitFor(app.staticTexts["Bash: rm -rf build/ && npm ci"])
        XCTAssertEqual(app.buttons.matching(identifier: "Allow once").count, 3)
        XCTAssertEqual(app.buttons.matching(identifier: "Deny").count, 3)
        screenshot("QA-004-smoke-decisions")
    }

    func testBotChat() {
        app.openBot("iOS Dev")
        waitFor(app.pane("Chat")).tap()
        // The bot's own transcript.
        waitFor(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Starting on the conflict banner'")).firstMatch)
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        waitFor(field).tap()
        let text = "UI smoke \(Int(Date().timeIntervalSince1970))"
        field.typeText(text)
        app.buttons["Send"].tap()
        waitFor(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch)
        screenshot("QA-004-smoke-chat")
    }

    func testAnswerDecision() {
        app.tab("Needs you")
        waitFor(app.needsRow("Launch the site with the offline headline?")).tap()
        waitFor(app.navigationBars["Decision"])
        app.buttons.containing(NSPredicate(format: "label CONTAINS 'Yes, go live Monday'")).firstMatch.tap()
        let publish = app.buttons["Publish ruling"]
        app.scroll(to: publish)
        XCTAssertTrue(publish.isEnabled)
        publish.tap()
        // Settled: the answer form gives way to the ruling.
        XCTAssertTrue(publish.waitForNonExistence(timeout: 10), "Still open after Publish ruling")
        screenshot("QA-004-smoke-decision-answered")
    }

    func testLinkSheetUnlink() {
        app.openProject("Aurora Notes")
        waitFor(app.navigationBars["Aurora Notes"].buttons["More"]).tap()
        waitFor(app.buttons["Project settings"]).tap()
        let change = app.buttons["Change linked computers"]
        app.scroll(to: change)
        waitFor(change).tap()
        waitFor(app.staticTexts["on Studio PC"])
        app.buttons["Unlink"].firstMatch.tap()
        // H-003: a confirmation first, and nothing unlinked yet.
        waitFor(app.staticTexts["Unlink Aurora Notes?"])
        XCTAssertTrue(app.staticTexts["on Studio PC"].exists)
        screenshot("QA-004-unlink-confirm")
        waitFor(app.buttons["Unlink project"]).tap()
        XCTAssertTrue(app.staticTexts["on Studio PC"].waitForNonExistence(timeout: 10), "Still linked after confirming Unlink")
        screenshot("QA-004-unlink-done")
    }
}
