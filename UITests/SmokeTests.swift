import XCTest

/// The main flows against the demo world: launch, Home, a bot's chat, answering a
/// decision, and the link sheet. Each test starts the app fresh.
final class SmokeTests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = try DemoApp.launch()
        allowSystemAlerts()
    }

    func testLaunchShowsHome() {
        waitFor(app.navigationBars["Home"])
        waitFor(app.buttons["Computer: Demo Mac"])
        for tab in ["Home", "Bots", "Decisions", "Files", "Computers"] {
            XCTAssertTrue(app.tabBars.buttons[tab].exists, "Tab \(tab)")
        }
    }

    func testHomeShowsWhatNeedsYou() {
        waitFor(app.staticTexts["Needs you"])
        // The demo's three permission prompts, each with its answers.
        waitFor(app.staticTexts["Bash: rm -rf build/ && npm ci"])
        XCTAssertEqual(app.buttons.matching(identifier: "Allow once").count, 3)
        XCTAssertEqual(app.buttons.matching(identifier: "Deny").count, 3)
        screenshot("QA-001-smoke-home")
    }

    func testBotChat() {
        app.tab("Bots")
        waitFor(app.botRow("iOS Dev")).tap()
        waitFor(app.buttons["Chat"])
        // The bot's own transcript.
        waitFor(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Starting on the conflict banner'")).firstMatch)
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        waitFor(field).tap()
        let text = "UI smoke \(Int(Date().timeIntervalSince1970))"
        field.typeText(text)
        app.buttons["Send"].tap()
        waitFor(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch)
        screenshot("QA-001-smoke-chat")
    }

    func testAnswerDecision() {
        app.tab("Decisions")
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Launch the site with the offline headline?'")).firstMatch
        app.scroll(to: row)
        waitFor(row).tap()
        waitFor(app.navigationBars["Decision"])
        app.buttons.containing(NSPredicate(format: "label CONTAINS 'Yes, go live Monday'")).firstMatch.tap()
        let publish = app.buttons["Publish ruling"]
        app.scroll(to: publish)
        XCTAssertTrue(publish.isEnabled)
        publish.tap()
        // Settled: the answer form gives way to the ruling.
        XCTAssertTrue(publish.waitForNonExistence(timeout: 10), "Still open after Publish ruling")
        screenshot("QA-001-smoke-decision-answered")
    }

    func testLinkSheetUnlink() {
        app.tab("Bots")
        // The project's header row opens it from its "Open".
        let header = waitFor(app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Aurora Notes,'")).firstMatch)
        header.staticTexts["Open"].tap()
        waitFor(app.navigationBars["Aurora Notes"])
        let change = app.buttons["Change linked computers"]
        app.scroll(to: change)
        waitFor(change).tap()
        waitFor(app.staticTexts["on Studio PC"])
        app.buttons["Unlink"].firstMatch.tap()
        // H-003: a confirmation first, and nothing unlinked yet.
        waitFor(app.staticTexts["Unlink Aurora Notes?"])
        XCTAssertTrue(app.staticTexts["on Studio PC"].exists)
        screenshot("QA-001-unlink-confirm")
        waitFor(app.buttons["Unlink project"]).tap()
        XCTAssertTrue(app.staticTexts["on Studio PC"].waitForNonExistence(timeout: 10), "Still linked after confirming Unlink")
        screenshot("QA-001-unlink-done")
    }
}
