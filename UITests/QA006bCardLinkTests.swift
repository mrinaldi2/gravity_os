import XCTest

/// QA-006b: H-204 card ids as links (UX-035), against the scratch daemon on a copy of
/// this Mac's board: the release changelog, a decision, a chat thread, a bot's
/// Reports, meeting minutes and comments; Back; the long-press menu; missing ids;
/// thehermes://item/…; names that are not ids. Skips without SCRATCH_PORT/SCRATCH_TOKEN.
final class QA006bCardLinkTests: XCTestCase {
    private var env: [String: String] { DemoApp.environment }
    /// In the copy: an open decision that names H-195.
    static let decisionWithId = "86609c87-c42a-4f5f-9550-00ba335b4171"

    override func setUpWithError() throws {
        continueAfterFailure = true
        if UIDevice.current.userInterfaceIdiom == .pad { throw XCTSkip("iPhone layout") }
        if (env["SCRATCH_PORT"] ?? "").isEmpty || (env["SCRATCH_TOKEN"] ?? "").isEmpty {
            throw XCTSkip("No scratch daemon (SCRATCH_PORT/SCRATCH_TOKEN)")
        }
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.appearance = .light
        let app = XCUIApplication()
        app.launchArguments = ["-gravHost", "127.0.0.1", "-gravPort", env["SCRATCH_PORT"]!,
                               "-gravToken", env["SCRATCH_TOKEN"]!, "-noNotificationPrompt", "YES"] + extra
        app.launch()
        return app
    }

    private func link(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.links.matching(NSPredicate(format: "label == %@", id)).firstMatch
    }

    /// Tap the id, see its card, go Back to where it was.
    private func tapThrough(_ app: XCUIApplication, _ id: String, from screen: String, capture: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        let target = link(app, id)
        app.scroll(to: target)
        guard target.waitForExistence(timeout: 10) else {
            return XCTFail("\(screen): \(id) is not a link", file: file, line: line)
        }
        let before = target.frame
        screenshot("QA-006b-\(capture)-link")
        target.tap()
        let card = app.navigationBars[id]
        XCTAssertTrue(card.waitForExistence(timeout: 15), "\(screen): tapping \(id) did not open its card", file: file, line: line)
        sleep(1)
        screenshot("QA-006b-\(capture)-card")
        waitFor(app.navigationBars.buttons["BackButton"], 5).tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 5), "\(screen): Back did not leave the card", file: file, line: line)
        // Back returns to the same place: the link is where it was.
        XCTAssertTrue(target.waitForExistence(timeout: 5), "\(screen): Back did not return to the text", file: file, line: line)
        XCTAssertEqual(target.frame.minY, before.minY, accuracy: 2, "\(screen): scroll not kept on Back", file: file, line: line)
    }

    /// The project screen loads from the cache first: re-tap the segment until `target` shows.
    private func segment(_ app: XCUIApplication, _ name: String, until target: XCUIElement) {
        let deadline = Date().addingTimeInterval(40)
        repeat {
            app.pane(name).tap()
            if target.waitForExistence(timeout: 4) { return }
            app.pane("Overview").tap()
            sleep(1)
        } while Date() < deadline
    }

    // MARK: Where ids link

    func testReleaseChangelogLinks() {
        let app = launch(["-openProject", "The Hermes", "-openSegment", "releases"])
        waitFor(app.navigationBars["The Hermes"], 30)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '0.17.4,'")).firstMatch
        segment(app, "Releases", until: row)
        waitFor(row).tap()
        for id in ["H-182", "H-184", "H-187", "H-178", "H-191", "H-155", "H-174", "H-183", "H-188"] {
            XCTAssertTrue(link(app, id).waitForExistence(timeout: 10), "Changelog: \(id) is not a link")
        }
        tapThrough(app, "H-182", from: "release changelog", capture: "changelog")
    }

    func testDecisionLinks() {
        let app = launch(["-route", "decision/\(Self.decisionWithId)"])
        waitFor(app.navigationBars["Decision"], 30)
        tapThrough(app, "H-195", from: "decision", capture: "decision")
    }

    func testChatThreadLinks() {
        let app = launch(["-openTab", "chat"])
        let thread = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Architect'")).firstMatch
        app.scroll(to: thread)
        waitFor(thread, 30).tap()
        tapThrough(app, "H-193", from: "chat thread", capture: "chat")
    }

    func testBotReportsLinks() {
        let app = launch(["-openProject", "The Hermes", "-openSegment", "team"])
        waitFor(app.navigationBars["The Hermes"], 30)
        let architect = app.botRow("Architect")
        segment(app, "Team", until: architect)
        app.scroll(to: architect)
        waitFor(architect).tap()
        waitFor(app.pane("Reports"), 15)
        tapThrough(app, "H-193", from: "Reports", capture: "reports")
    }

    func testMeetingMinutesLinks() {
        let app = launch(["-openProject", "The Hermes", "-openSegment", "meet"])
        waitFor(app.navigationBars["The Hermes"], 30)
        let anyLink = app.links.matching(NSPredicate(format: "label == 'H-019' OR label == 'H-123'")).firstMatch
        let meet = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Meet'")).firstMatch
        let deadline = Date().addingTimeInterval(40)
        repeat {
            meet.tap()
            // The stand-up's minutes: open it when it is a row.
            let standup = app.buttons.matching(NSPredicate(format: "label CONTAINS 'stand-up' OR label CONTAINS 'Stand-up'")).firstMatch
            if standup.waitForExistence(timeout: 4), !anyLink.exists { standup.tap(); sleep(2) }
            if anyLink.waitForExistence(timeout: 4) { break }
            app.pane("Overview").tap()
        } while Date() < deadline
        screenshot("QA-006b-minutes")
        tapThrough(app, anyLink.exists ? anyLink.label : "H-123", from: "meeting minutes", capture: "minutes")
    }

    /// A comment of mine (in the copy): ids link, names and other words with digits don't,
    /// a missing id says so, and the long-press menu names each card.
    func testCommentLinksNonLinksMissingAndLongPress() {
        let app = launch(["-openProject", "The Hermes", "-openSegment", "board"])
        waitFor(app.navigationBars["The Hermes"], 30)
        let inbox = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Inbox'")).firstMatch
        segment(app, "Board", until: inbox)
        inbox.tap()
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'H-155'")).firstMatch
        app.scroll(to: card)
        waitFor(card, 15).tap()
        waitFor(app.navigationBars["H-155"], 15)

        let stamp = Int(Date().timeIntervalSince1970)
        let text = "QA-006b \(stamp): see H-189 and `H-190`, not H-189-project-clicks, SHA-256 or UTF-8; missing H-9999."
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        app.scroll(to: field)
        waitFor(field).tap()
        field.typeText(text)
        app.buttons["Send"].tap()
        let comment = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "QA-006b \(stamp)")).firstMatch
        waitFor(comment, 20)
        if app.keyboards.firstMatch.exists { app.navigationBars["H-155"].tap() }
        app.scroll(to: comment)
        sleep(2)
        screenshot("QA-006b-comment-links")

        // Linked: H-189 and the inline-code `H-190`. Not linked: the branch name, SHA-256, UTF-8.
        let inComment = comment.links
        let labels = inComment.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(labels.contains("H-189"), "H-189 not linked: \(labels)")
        XCTAssertTrue(labels.contains("H-190"), "`H-190` not linked: \(labels)")
        XCTAssertEqual(labels.filter { $0 == "H-189" }.count, 1, "H-189-project-clicks linked as H-189: \(labels)")
        for word in ["H-189-project-clicks", "SHA-256", "UTF-8"] {
            XCTAssertFalse(labels.contains(word), "\(word) is linked: \(labels)")
        }

        // A missing id: the §8 words, and nothing navigates.
        let missing = inComment.matching(NSPredicate(format: "label == 'H-9999'")).firstMatch
        if missing.exists {
            missing.tap()
            let words = app.staticTexts.containing(NSPredicate(format: "label CONTAINS \"H-9999 isn't on\" OR label CONTAINS 'H-9999 isn’t on'")).firstMatch
            XCTAssertTrue(words.waitForExistence(timeout: 10), "No \"H-9999 isn't on <project>'s board…\" words")
            screenshot("QA-006b-missing-id")
            XCTAssertFalse(app.navigationBars["H-9999"].exists, "A missing id navigated")
            if app.alerts.firstMatch.exists { app.alerts.buttons.firstMatch.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap() }
        } else {
            XCTFail("H-9999 (a prefix this phone knows) is not a link, so its missing-card words can't show")
        }

        // Long-press the comment: each card named, with Open card and Copy.
        comment.press(forDuration: 1.5)
        let named = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'H-189 · '")).firstMatch
        let open = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Open card'")).firstMatch
        let copy = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Copy H-189'")).firstMatch
        let shown = named.waitForExistence(timeout: 8) || open.waitForExistence(timeout: 2)
        screenshot("QA-006b-long-press")
        XCTAssertTrue(shown, "Long-press shows no card menu")
        if named.exists { named.tap(); sleep(1); screenshot("QA-006b-long-press-card-menu") }
        XCTAssertTrue(open.waitForExistence(timeout: 5), "No Open card")
        XCTAssertTrue(copy.exists, "No Copy H-189")
        open.tap()
        XCTAssertTrue(app.navigationBars["H-189"].waitForExistence(timeout: 15), "Open card did not open H-189")
        screenshot("QA-006b-long-press-opened")
    }

    /// A single id's long-press preview: heading, title, where it is; Open card and Copy.
    func testLongPressPreviewOnASingleId() {
        let app = launch(["-route", "decision/\(Self.decisionWithId)"])
        waitFor(app.navigationBars["Decision"], 30)
        let target = link(app, "H-195")
        waitFor(target, 15)
        // The text block that holds the id.
        let block = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'H-195'")).firstMatch
        (block.exists ? block : target).press(forDuration: 1.5)
        sleep(2)
        screenshot("QA-006b-preview")
        let words = app.visibleWords.joined(separator: " | ")
        XCTAssertTrue(words.contains("Open card"), "No Open card in the preview")
        XCTAssertTrue(words.contains("Copy H-195"), "No Copy H-195 in the preview")
        XCTAssertTrue(words.contains("H-195 · "), "The preview does not name the card: \(words.prefix(400))")
    }

    // MARK: From outside

    /// warm: through the system, into the running app; cold: XCUIApplication.open relaunches the app with the URL.
    private func openOutside(_ app: XCUIApplication, _id: String, warm: Bool = true) {
        let url = URL(string: "thehermes://item/\(_id)")!
        if warm { XCUIDevice.shared.system.open(url) } else { app.open(url) }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Open"].waitForExistence(timeout: 3) { springboard.buttons["Open"].tap() }
    }

    /// Prefixes known (a changelog link is on screen), back on Projects home, then the outside link.
    func testOutsideLinkOpensTheCard() {
        let app = launch(["-openProject", "The Hermes", "-openSegment", "releases"])
        waitFor(app.navigationBars["The Hermes"], 30)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '0.17.4,'")).firstMatch
        segment(app, "Releases", until: row)
        waitFor(row).tap()
        XCTAssertTrue(link(app, "H-182").waitForExistence(timeout: 15), "prefix H not known")
        while app.navigationBars.buttons["BackButton"].exists { app.navigationBars.buttons["BackButton"].tap(); sleep(1) }
        waitFor(app.navigationBars["Projects"], 10)
        openOutside(app, _id: "H-189")
        XCTAssertTrue(app.navigationBars["H-189"].waitForExistence(timeout: 20), "thehermes://item/H-189 did not open the card")
        XCTAssertTrue(app.tabBars.buttons["Projects"].isSelected, "Not opened on the Projects tab")
        screenshot("QA-006b-outside-link")
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertFalse(app.navigationBars["H-189"].waitForExistence(timeout: 3), "Back did not leave the card")
    }

    /// The link arrives right after launch, before the boards have answered.
    func testOutsideLinkOnColdStart() {
        let app = launch()
        waitFor(app.tabBars.buttons["Projects"], 30)
        openOutside(app, _id: "H-189", warm: false)
        let opened = app.navigationBars["H-189"].waitForExistence(timeout: 30)
        screenshot("QA-006b-outside-link-cold")
        XCTAssertTrue(opened, "thehermes://item/H-189 on a cold start did not open the card")
    }
}
