import XCTest

/// H-214 (iOS 0.6.1 hotfix): a long-press on a single card's row or block-Markdown text
/// shows the card preview and does not crash (the 0.6.0 SwiftUI context-menu preview
/// lacked Fleet). Scratch daemon on a copy of this Mac's board.
final class H214Tests: XCTestCase {
    private var env: [String: String] { DemoApp.environment }

    override func setUpWithError() throws {
        continueAfterFailure = true
        if UIDevice.current.userInterfaceIdiom == .pad { throw XCTSkip("iPhone layout") }
        if (env["SCRATCH_PORT"] ?? "").isEmpty || (env["SCRATCH_TOKEN"] ?? "").isEmpty {
            throw XCTSkip("No scratch daemon (SCRATCH_PORT/SCRATCH_TOKEN)")
        }
    }

    private func launch(_ extra: [String]) -> XCUIApplication {
        XCUIDevice.shared.appearance = .light
        let app = XCUIApplication()
        app.launchArguments = ["-gravHost", "127.0.0.1", "-gravPort", env["SCRATCH_PORT"]!,
                               "-gravToken", env["SCRATCH_TOKEN"]!, "-noNotificationPrompt", "YES"] + extra
        app.launch()
        return app
    }

    /// Long-press, then: still running, a preview naming `id` (or any card), Open card and Copy.
    private func pressAndCheck(_ app: XCUIApplication, _ target: XCUIElement, id: String?, capture: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        target.press(forDuration: 1.5)
        sleep(3)
        screenshot(capture)
        XCTAssertEqual(app.state, .runningForeground, "\(capture): the app crashed on long-press", file: file, line: line)
        let words = app.visibleWords.joined(separator: " | ")
        XCTAssertTrue(words.contains("Open card"), "\(capture): no Open card: \(words.prefix(300))", file: file, line: line)
        let card = id ?? "H-"
        XCTAssertTrue(words.contains("Copy \(card)"), "\(capture): no Copy \(card)", file: file, line: line)
        XCTAssertTrue(words.contains("\(card)") && words.contains(" · "), "\(capture): the preview does not name the card", file: file, line: line)
        // Close the menu.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
    }

    func testLongPressReleaseItemRow() {
        let app = launch(["-openProject", "The Hermes", "-openSegment", "releases"])
        waitFor(app.navigationBars["The Hermes"], 30)
        // A seeded package awaiting the owner (top of the list): its rows are H-108, H-118, H-134.
        let release = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'iOS 0.5.0-qb1,'")).firstMatch
        let deadline = Date().addingTimeInterval(45)
        repeat {
            app.pane("Releases").tap()
            if release.waitForExistence(timeout: 4) { break }
            app.pane("Overview").tap(); sleep(1)
        } while Date() < deadline
        app.scroll(to: release)
        waitFor(release).tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'H-134 · '")).firstMatch
        app.scroll(to: row)
        waitFor(row, 15)
        pressAndCheck(app, row, id: "H-134", capture: "QA-008-h214-release-item-row")
    }

    func testLongPressNeedsYouCardRow() {
        let app = launch(["-openTab", "needs"])
        let row = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "^[A-Z]+-[0-9]+ .*")).firstMatch
        _ = app.buttons.matching(NSPredicate(format: "label CONTAINS ' · '")).firstMatch.waitForExistence(timeout: 30)
        var seen = Set<String>()
        for _ in 0..<25 where !row.exists {
            app.buttons.allElementsBoundByIndex.forEach { seen.insert(String($0.label.prefix(70))) }
            app.swipeUp(); sleep(1)
        }
        guard row.exists else { return XCTFail("No Needs you row about a card. Rows: \(seen.sorted())") }
        app.scroll(to: row)
        let id = String(row.label.prefix { $0 != " " })
        pressAndCheck(app, row, id: id, capture: "QA-008-h214-needs-you-card-row")
    }

    /// Block Markdown naming one card: QA-006b's task request (a list; only H-204 is an id).
    func testLongPressListNamingOneCard() {
        let app = launch(["-openProject", "The Hermes", "-openSegment", "team", "-openPane", "Work"])
        waitFor(app.navigationBars["The Hermes"], 30)
        let me = app.botRow("Architect")
        let deadline = Date().addingTimeInterval(45)
        while !me.exists, Date() < deadline { app.pane("Team").tap(); sleep(3) }
        waitFor(me).tap()
        // The Architect's task "Review H-193 @ 22d8694 …": a list naming only H-193.
        let task = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Review H-193 @ 22d8694'")).firstMatch
        for _ in 0..<60 where !task.exists { app.swipeUp(velocity: .fast) }
        app.scroll(to: task, max: 10)
        waitFor(task, 20).tap()
        let block = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'H-193-no-silent-daemon-swap'")).firstMatch
        app.scroll(to: block)
        waitFor(block, 15)
        screenshot("QA-008-h214-list-task")
        pressAndCheck(app, block, id: "H-193", capture: "QA-008-h214-list-naming-one-card")
    }
}
