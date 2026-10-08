import XCTest

/// H-228: the bot transcript is lazy again. With earlier pages loaded and the chat read
/// from the top, Send still lands on the sent line, and the transcript never goes blank
/// (the H-227 bug). Needs iOS Dev's demo log given earlier turns: LONG_CHAT=1 (QA-010's
/// demo/long_chat.py) and DEMO_BOT_ID, as scripts/ui-tests.sh passes it.
final class H228Tests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        if (DemoApp.environment["LONG_CHAT"] ?? "").isEmpty { throw XCTSkip("No long demo transcript (LONG_CHAT)") }
        if UIDevice.current.userInterfaceIdiom == .pad { throw XCTSkip("iPhone layout") }
        let bot = try XCTUnwrap(DemoApp.botId, "No DEMO_BOT_ID: run scripts/ui-tests.sh")
        app = try DemoApp.launch(["-route", "waiting/\(bot)", "-noNotificationPrompt", "YES"])
        allowSystemAlerts()
    }

    private func any(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
    }

    /// Drags inside the transcript, below the pinned permission card. `up` reveals earlier turns.
    private func drag(up: Bool) {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.55 : 0.85))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.88 : 0.52))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0)
    }

    func testSendFromTheTopWithEarlierPagesLoadedShowsTheLine() {
        waitFor(app.buttons["Chat"])
        sleep(3) // the newest page loads
        let more = app.buttons["Load earlier turns"]
        var pages = 0
        while pages < 10 {
            for _ in 0..<60 where !(more.exists && more.isHittable) { drag(up: true) }
            guard more.exists && more.isHittable else { break }
            more.tap()
            pages += 1
            sleep(2)
        }
        XCTAssertGreaterThanOrEqual(pages, 2, "Fewer earlier pages than the long transcript holds")
        XCTAssertLessThanOrEqual(pages, 5, "More than 5 earlier pages loaded")
        // At the top of what is loaded.
        for _ in 0..<30 { drag(up: true) }
        screenshot("H-228-top")

        let field = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Message iOS Dev' OR placeholderValue == 'Message iOS Dev'")).firstMatch
        waitFor(field).tap()
        let text = "H-228 send \(Int(Date().timeIntervalSince1970))"
        field.typeText(text)
        app.buttons["Send"].tap()
        let sent = any(text)
        XCTAssertTrue(sent.waitForExistence(timeout: 10), "The transcript did not land on the sent line")
        XCTAssertTrue(sent.isHittable, "The sent line is not on screen")
        screenshot("H-228-after-send")
    }
}
