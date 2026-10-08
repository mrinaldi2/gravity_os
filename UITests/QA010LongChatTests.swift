import XCTest

/// H-227: the bot transcript is a plain VStack now, not lazy. With many earlier pages
/// loaded, the chat still scrolls, still sends, and its memory stays bounded.
/// Needs a long demo transcript: LONG_CHAT=1 means iOS Dev's log was given extra
/// earlier turns (the QA bot's long_chat.py) before the run.
final class QA010LongChatTests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        if (DemoApp.environment["LONG_CHAT"] ?? "").isEmpty { throw XCTSkip("No long demo transcript (LONG_CHAT)") }
        if UIDevice.current.userInterfaceIdiom == .pad { throw XCTSkip("iPhone layout") }
        app = try DemoApp.launch()
        allowSystemAlerts()
    }

    private func any(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
    }

    /// Drags inside the transcript, below the pinned permission card (a whole-app swipe
    /// starts on the card and scrolls nothing). `up` reveals earlier turns.
    private func drag(up: Bool) {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.55 : 0.85))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.88 : 0.52))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0)
    }

    private func scrollTranscript(to element: XCUIElement, max: Int = 60) {
        var tries = 0
        while !(element.exists && element.isHittable), tries < max { drag(up: true); tries += 1 }
    }

    /// Scrolls up to the top of what is loaded and taps "Load earlier turns" while it shows.
    private func loadAllPages(max: Int = 20) -> Int {
        let more = app.buttons["Load earlier turns"]
        var pages = 0
        while pages < max {
            for _ in 0..<60 where !(more.exists && more.isHittable) { drag(up: true) }
            guard more.exists && more.isHittable else { break }
            more.tap()
            pages += 1
            sleep(2)
        }
        return pages
    }

    func testLongChatLoadsScrollsAndSends() {
        app.openBot("iOS Dev")
        waitFor(app.pane("Chat")).tap()
        waitFor(any("Long chat turn"), 20)
        let t0 = Date()
        let pages = loadAllPages()
        let loadTime = Date().timeIntervalSince(t0)
        XCTContext.runActivity(named: "Loaded \(pages) earlier pages in \(String(format: "%.1f", loadTime)) s") { _ in }
        print("QA-010 long chat: \(pages) earlier pages loaded in \(String(format: "%.1f", loadTime)) s")
        XCTAssertGreaterThanOrEqual(pages, 2, "Fewer earlier pages than the long transcript holds")
        // The oldest turn is there and readable.
        let oldest = any("Long chat turn 1:")
        scrollTranscript(to: oldest)
        XCTAssertTrue(oldest.exists, "The oldest turn is not in the transcript")
        screenshot("QA-010-long-chat-top")

        // Scrolling the full transcript: hitches and memory, three passes top to bottom and back.
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric, XCTMemoryMetric(application: app)], options: options) {
            for _ in 0..<8 { drag(up: false) }
            for _ in 0..<8 { drag(up: true) }
        }

        // Send from the top of the long transcript (H-227): the transcript stays, the line shows.
        let field = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Message iOS Dev' OR placeholderValue == 'Message iOS Dev'")).firstMatch
        waitFor(field).tap()
        let text = "Long chat send \(Int(Date().timeIntervalSince1970))"
        field.typeText(text)
        app.buttons["Send"].tap()
        let sent = any(text)
        XCTAssertTrue(sent.waitForExistence(timeout: 15), "The sent line did not show in a long transcript")
        XCTAssertTrue(any("Turn ").exists, "The transcript went blank after sending")
        screenshot("QA-010-long-chat-after-send")
        XCTAssertEqual(app.state, .runningForeground)
    }
}
