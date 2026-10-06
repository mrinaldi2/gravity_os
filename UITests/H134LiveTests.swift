import XCTest

/// H-134 against a 0.17 daemon (the demo world on desktop 0.17.0's hermesd): the live
/// overview, pinning, cache-first, Run cards, decision grants (H-118), the terminal
/// command card (H-108), the binary board and owner threads. Each test seeds what it
/// needs through the demo's control endpoint, in its own "Hermes Lab" project, and
/// skips on an older daemon.
final class H134LiveTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        if UIDevice.current.userInterfaceIdiom == .pad { throw XCTSkip("iPhone layout; the iPad has H134LivePadTests") }
        try requireLiveDaemon()
    }

    // MARK: I1 live overview, pinning, cache-first

    func testLiveCardsAndPinning() throws {
        let app = try DemoApp.launch()
        allowSystemAlerts()
        let aurora = waitFor(app.projectCard("Aurora Notes"), 20)
        XCTAssertFalse(aurora.label.contains("Update needed"), "A 0.17 daemon still gets the older-daemon card: \(aurora.label)")
        XCTAssertTrue(aurora.label.contains("bots"), aurora.label)
        screenshot("QA-004-live-projects")

        // Long press → Pin to top (project_pin), then back.
        aurora.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.5)
        waitFor(app.buttons["Pin to top"], 5).tap()
        XCTAssertTrue(waitForPins(contains: "Aurora Notes"), "The daemon did not record the pin")
        let pinned = app.projectCard("Aurora Notes")
        XCTAssertTrue(pinned.waitForExistence(timeout: 10) && pinned.label.contains("Pinned"), "No pin on the card: \(pinned.label)")
        screenshot("QA-004-live-pinned")
        pinned.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.5)
        waitFor(app.buttons["Unpin"], 5).tap()
        XCTAssertTrue(waitForPins(contains: nil), "The pin did not come off")
    }

    /// The last overview shows before the network: relaunched against a closed port, the
    /// cards are still there.
    func testLiveCacheFirst() throws {
        var app = try DemoApp.launch()
        allowSystemAlerts()
        waitFor(app.projectCard("Aurora Notes"), 20)
        sleep(2)
        app.terminate()
        app = try DemoApp.launch(port: "41309") // in my range, nothing listens there
        let cached = app.projectCard("Aurora Notes")
        XCTAssertTrue(cached.waitForExistence(timeout: 8), "No cached overview while the computer is unreachable")
        XCTAssertFalse(cached.label.contains("Update needed"), "The cached card is the older-daemon one: \(cached.label)")
        screenshot("QA-004-live-cache-first")
    }

    // MARK: Needs you: Run card

    func testLiveRunCard() throws {
        try seed("/runcard")
        let app = try DemoApp.launch()
        allowSystemAlerts()
        app.tab("Needs you")
        let row = waitFor(app.needsRow("Run: Clear the stale build cache"), 20)
        screenshot("QA-004-live-run-card-row")
        row.tap()
        // Running it from the phone comes later in the 0.5.0 lane: the row says where.
        let note = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Run cards come to the phone'")).firstMatch
        waitFor(note, 10)
        screenshot("QA-004-live-run-card-note")
    }

    // MARK: I2b: decision grants (H-118)

    func testLiveDecisionGrants() throws {
        try seed("/grants")
        let app = try DemoApp.launch()
        allowSystemAlerts()
        app.tab("Needs you")
        waitFor(app.needsRow("Let DevOps install 0.17.1"), 20).tap()
        waitFor(app.navigationBars["Decision"])
        let grants = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Grants '")).firstMatch
        waitFor(grants, 10)
        for part in ["DevOps: install", "Desktop Dev: publish"] {
            XCTAssertTrue(grants.label.contains(part), "\"\(part)\" missing from: \(grants.label)")
        }
        screenshot("QA-004-live-grants")
        // Publishing the granting option echoes grants_sha; a mismatch would be refused.
        app.buttons.containing(NSPredicate(format: "label CONTAINS 'Grant both'")).firstMatch.tap()
        let publish = app.buttons["Publish ruling"]
        app.scroll(to: publish)
        publish.tap()
        XCTAssertTrue(publish.waitForNonExistence(timeout: 10), "Publishing a granting option did not settle it")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'conflict' OR label CONTAINS[c] 'changed'")).firstMatch.exists,
                       "A grants conflict on a fresh decision")
        screenshot("QA-004-live-grants-published")
    }

    // MARK: I2b: the terminal command card (H-108)

    func testLiveTerminalCard() throws {
        try seed("/terminal")
        let app = try DemoApp.launch()
        allowSystemAlerts()
        app.tab("Needs you")
        let title = app.staticTexts["A terminal command wants to act as you"]
        let shown = title.waitForExistence(timeout: 20)
        screenshot("QA-004-live-terminal-card")
        XCTAssertTrue(shown, "No terminal command card on Needs you (the daemon holds one for clients with the terminal_card feature)")
        if shown {
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'git push --force origin main'")).firstMatch.exists)
            XCTAssertFalse(app.buttons["Allow once"].exists && app.buttons["Allow once"].isHittable && title.frame.minY < app.buttons["Allow once"].frame.minY,
                           "The terminal card offers answers on the phone")
        }
    }

    // MARK: I2: the binary board

    func testLiveBoard() throws {
        try seed("/lab")
        let app = try DemoApp.launch(["-openProject", "Hermes Lab", "-openSegment", "board"])
        allowSystemAlerts()
        waitFor(app.navigationBars["Hermes Lab"], 20)
        sleep(3) // board_get creates the board for the owner
        let items = try seed("/items")
        XCTAssertEqual(items["ok"] as? Bool, true, "Seeding items: \(items)")
        // Back and forth refreshes the board.
        app.pane("Overview").tap()
        app.pane("Board").tap()
        // The column chips count the cards: new items land in Inbox.
        let inbox = waitFor(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Inbox'")).firstMatch, 20)
        XCTAssertEqual(inbox.label, "Inbox 3", "Inbox chip")
        screenshot("QA-004-live-board-chips")
        inbox.tap()
        sleep(2)
        let item = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Board chips on iPad'")).firstMatch
        let shown = item.waitForExistence(timeout: 10)
        screenshot("QA-004-live-board")
        XCTAssertTrue(shown, "Inbox counts 3 cards but its page shows none")
        guard shown else { return }
        item.tap()
        sleep(2)
        screenshot("QA-004-live-board-item")
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        if field.waitForExistence(timeout: 5) {
            field.tap()
            field.typeText("QA-004 comment from the phone")
            app.buttons["Send"].tap()
            waitFor(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'QA-004 comment from the phone'")).firstMatch, 10)
            screenshot("QA-004-live-board-comment")
        } else {
            XCTFail("No comment field on the item")
        }
    }

    // MARK: I3: owner threads

    func testLiveOwnerThreads() throws {
        try seed("/question")
        let app = try DemoApp.launch()
        allowSystemAlerts()
        app.tab("Chat")
        waitFor(app.navigationBars["Chat"])
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Threads come with'")).firstMatch.exists,
                       "A 0.17 daemon still gets the threads fallback")
        let question = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Desktop Dev'")).firstMatch
        waitFor(question, 20)
        XCTAssertTrue(question.label.contains("Question"), "No Question pill: \(question.label)")
        XCTAssertTrue(question.label.contains("unread"), "No unread count: \(question.label)")
        let own = app.buttons.matching(NSPredicate(format: "label CONTAINS 'iOS Dev'")).firstMatch
        XCTAssertTrue(own.exists && own.label.contains("You: "), "No \"You: \" on the owner's last message: \(own.label)")
        // Open questions first.
        XCTAssertLessThan(question.frame.minY, own.frame.minY, "The open question is not first")
        screenshot("QA-004-live-threads")

        question.tap()
        waitFor(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Should the release notes mention the new board?'")).firstMatch)
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        waitFor(field).tap()
        field.typeText("Yes, mention it.")
        app.buttons["Send"].tap()
        waitFor(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Yes, mention it.'")).firstMatch, 10)
        screenshot("QA-004-live-thread")

        // Read: back on the list, no unread count.
        app.tab("Chat")
        let after = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Desktop Dev'")).firstMatch
        waitFor(after)
        sleep(2)
        XCTAssertFalse(after.label.contains("unread"), "Still unread after reading: \(after.label)")
    }

    // MARK: I2: the bot page's Reports, live

    func testLiveBotReports() throws {
        try seed("/question")
        let app = try DemoApp.launch(["-openProject", "Hermes Lab", "-openSegment", "team"])
        allowSystemAlerts()
        waitFor(app.botRow("Desktop Dev"), 20).tap()
        waitFor(app.pane("Reports"))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Reports come from The Hermes 0.17'")).firstMatch.exists,
                       "A 0.17 daemon still gets the Reports fallback")
        waitFor(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Should the release notes mention the new board?'")).firstMatch, 15)
        let answer = waitFor(app.buttons["Answer in Chat"].firstMatch)
        screenshot("QA-004-live-reports")
        answer.tap()
        let composer = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Message Desktop Dev' OR placeholderValue == 'Message Desktop Dev'")).firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10) || app.textViews.firstMatch.exists, "Answer in Chat did not open a composer")
    }

    // MARK: helpers

    @discardableResult
    private func seed(_ path: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let reply = try DemoControl.post(path)
        if let ok = reply["ok"] as? Bool, !ok, path != "/items" {
            XCTFail("Seeding \(path): \(reply)", file: file, line: line)
        }
        return reply
    }

    private func waitForPins(contains name: String?) -> Bool {
        for _ in 0..<20 {
            let pinned = ((try? DemoControl.post("/pins"))?["pinned"] as? [String]) ?? []
            if name.map({ pinned.contains($0) }) ?? pinned.isEmpty { return true }
            usleep(500_000)
        }
        return false
    }
}

/// The live iPad: ranked projects in the sidebar, owner threads in the chat panel.
final class H134LivePadTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        if UIDevice.current.userInterfaceIdiom != .pad { throw XCTSkip("iPad only") }
        XCUIDevice.shared.orientation = .portrait
        try requireLiveDaemon()
    }

    func testLiveSidebarAndThreadsPanel() throws {
        _ = try DemoControl.post("/question")
        _ = try DemoControl.post("/grants")
        let app = try DemoApp.launch()
        allowSystemAlerts()
        waitFor(app.navigationBars["The Hermes"], 20)
        let lab = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Hermes Lab'")).firstMatch
        waitFor(lab, 20)
        screenshot("QA-004-live-ipad-sidebar")
        lab.tap()
        waitFor(app.buttons["Overview"].firstMatch, 10)
        waitFor(app.buttons["Main chat"]).tap()
        let thread = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Desktop Dev'")).firstMatch
        waitFor(thread, 15)
        XCTAssertTrue(thread.label.contains("Question"), thread.label)
        screenshot("QA-004-live-ipad-threads-panel")
    }
}

/// Skips a test unless the demo daemon offers the 0.17 home (and creates the Lab project).
func requireLiveDaemon() throws {
    let reply = try DemoControl.post("/lab")
    let caps = reply["caps"] as? [String] ?? []
    if !caps.contains("owner_threads") || !caps.contains("projects_overview") {
        throw XCTSkip("The demo daemon predates 0.17 (no owner_threads/projects_overview)")
    }
}
