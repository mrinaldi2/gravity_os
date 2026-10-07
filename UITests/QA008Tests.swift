import XCTest

/// QA-008 (iOS 0.6.1): H-210 Reply sheet and Dismiss, UX-041 comment copy, H-212 every card
/// link reachable. Scratch daemon on a copy of this Mac's board; scratch_control.py freezes it
/// for the failure path. Skips without SCRATCH_PORT/SCRATCH_TOKEN.
final class QA008Tests: XCTestCase {
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

    @discardableResult
    private func control(_ path: String) -> [String: Any] {
        guard let port = env["SCRATCH_CONTROL_PORT"], !port.isEmpty else { return [:] }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        var result: [String: Any] = [:]
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            result = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any] ?? [:]
            done.signal()
        }.resume()
        done.wait()
        return result
    }

    private func any(_ app: XCUIApplication, _ format: String, _ args: CVarArg...) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: format, argumentArray: args)).firstMatch
    }

    private func openCard(_ app: XCUIApplication, _ id: String) {
        waitFor(app.navigationBars["The Hermes"], 30)
        let inbox = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Inbox'")).firstMatch
        let deadline = Date().addingTimeInterval(45)
        repeat {
            app.pane("Board").tap()
            if inbox.waitForExistence(timeout: 4) { break }
            app.pane("Overview").tap(); sleep(1)
        } while Date() < deadline
        inbox.tap()
        let card = any(app, "label CONTAINS %@", id)
        app.scroll(to: card)
        waitFor(card, 15).tap()
        waitFor(app.navigationBars[id], 15)
    }

    private func composer(_ app: XCUIApplication) -> XCUIElement {
        let p = NSPredicate(format: "label == 'Comment' OR placeholderValue BEGINSWITH 'Comment on'")
        return app.textViews.matching(p).firstMatch.exists ? app.textViews.matching(p).firstMatch : app.textFields.matching(p).firstMatch
    }

    /// H-210: Reply opens "Reply to <bot>", posts with reply_to; UX-041 "✓ Posted. <names> are told."
    func testReplySheetPostsAndPostedLine() {
        let app = launch(["-openProject", "The Hermes", "-openSegment", "board"])
        openCard(app, "H-155")
        let reply = app.buttons["Reply"].firstMatch
        app.scroll(to: reply, max: 15)
        waitFor(reply, 10).tap()
        let sheet = app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH 'Reply to '")).firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Reply did not open a 'Reply to <bot>' sheet")
        screenshot("QA-008-h210-reply-sheet")
        let stamp = Int(Date().timeIntervalSince1970)
        app.typeText("QA-008 reply \(stamp)")  // the field is focused
        sheet.buttons["Send"].tap()
        let posted = any(app, "label BEGINSWITH '✓ Posted.'")
        let mine = any(app, "label CONTAINS %@", "QA-008 reply \(stamp)")
        // The reply lands under its comment, often far down a long card.
        // Nested under the comment it answers: look both ways, posted line first (it may be brief).
        var sawPosted = posted.exists
        for _ in 0..<20 where !(mine.exists && mine.isHittable) { app.swipeDown(); sawPosted = sawPosted || posted.exists }
        for _ in 0..<40 where !(mine.exists && mine.isHittable) { app.swipeUp(); sawPosted = sawPosted || posted.exists }
        if posted.exists { print("QA-008 posted line: \(posted.label)") }
        screenshot("QA-008-h210-reply-nested")
        XCTAssertTrue(sawPosted || posted.waitForExistence(timeout: 3), "No '✓ Posted. … are told.' line")
        screenshot("QA-008-ux041-posted")
        XCTAssertTrue(mine.exists, "The reply is not on the card")
        print("QA-008 posted line: \(posted.exists ? posted.label : "-")")
    }

    /// UX-041: a comment that fails reads "Couldn't post your comment. <reason>".
    func testCouldntPostYourComment() throws {
        if (env["SCRATCH_CONTROL_PORT"] ?? "").isEmpty { throw XCTSkip("no control port") }
        let app = launch(["-openProject", "The Hermes", "-openSegment", "board"])
        openCard(app, "H-155")
        let field = composer(app)
        app.scroll(to: field, max: 15)
        waitFor(field).tap()
        control("/freeze")
        defer { control("/thaw") }
        field.typeText("QA-008 not posted \(Int(Date().timeIntervalSince1970))")
        app.buttons["Send"].tap()
        let words = any(app, "label BEGINSWITH 'Couldn’t post your comment.' OR label BEGINSWITH \"Couldn't post your comment.\"")
        let shown = words.waitForExistence(timeout: 60)
        screenshot("QA-008-ux041-couldnt-post")
        XCTAssertTrue(shown, "No \"Couldn't post your comment. <reason>\"")
        if shown { print("QA-008 failure line: \(words.label)") }
        control("/thaw")
        if app.buttons["Discard"].exists { app.buttons["Discard"].tap() }
    }

    /// H-210: swipe Dismiss on a bot's question in Needs you: it leaves, or "Couldn't dismiss this question".
    func testDismissAQuestion() {
        let app = launch(["-openTab", "needs"])
        let question = app.buttons.matching(NSPredicate(format: "label CONTAINS ', Question'")).firstMatch
        let deadline = Date().addingTimeInterval(40)
        while !question.exists, Date() < deadline { app.swipeUp(); sleep(1) }
        guard question.exists else { return XCTFail("No question row in Needs you") }
        app.scroll(to: question)
        let label = question.label
        screenshot("QA-008-h210-needs-question")
        question.swipeLeft()
        let dismiss = app.buttons["Dismiss"].firstMatch
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5), "No swipe Dismiss on a question")
        screenshot("QA-008-h210-swipe-dismiss")
        dismiss.tap()
        let alert = app.alerts["Couldn’t dismiss this question"]
        let gone = NSPredicate(format: "exists == false")
        let same = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
        let left = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: same)], timeout: 15) == .completed
        screenshot("QA-008-h210-after-dismiss")
        if alert.exists {
            print("QA-008 dismiss alert: \(alert.staticTexts.allElementsBoundByIndex.map(\.label))")
            XCTFail("Dismiss refused: \(alert.staticTexts.allElementsBoundByIndex.map(\.label))")
        } else {
            XCTAssertTrue(left, "The dismissed question is still listed")
        }
    }

    /// H-212: a text naming several cards exposes each as a link with its title.
    func testEveryLinkInAMultiIdTextIsReachable() {
        let app = launch(["-openProject", "The Hermes", "-openSegment", "releases"])
        waitFor(app.navigationBars["The Hermes"], 30)
        let release = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '0.17.4,'")).firstMatch
        let deadline = Date().addingTimeInterval(45)
        repeat {
            app.pane("Releases").tap()
            if release.waitForExistence(timeout: 4) { break }
            for _ in 0..<6 where !release.exists { app.swipeUp() }
            if release.exists { break }
            app.pane("Overview").tap(); sleep(1)
        } while Date() < deadline
        app.scroll(to: release, max: 15)
        waitFor(release).tap()
        sleep(4)  // titles arrive
        screenshot("QA-008-h212-changelog")
        var labels: [String: String] = [:]
        for id in ["H-182", "H-184", "H-187", "H-178", "H-191", "H-155", "H-174", "H-183", "H-188"] {
            let link = app.links.matching(NSPredicate(format: "label BEGINSWITH %@ OR label == %@", "\(id):", "\(id), card")).firstMatch
            if link.exists, link.frame.width > 0 { labels[id] = link.label }
        }
        XCTContext.runActivity(named: "links: \(labels)") { _ in }
        XCTAssertEqual(labels.count, 9, "Not every changelog id is a reachable link: \(labels.keys.sorted())")
        XCTAssertTrue(labels.values.filter { $0.contains(":") }.count >= 8, "Links without their titles: \(labels)")
        // Tap one in the middle: it opens its card.
        let h155 = app.links.matching(NSPredicate(format: "label BEGINSWITH 'H-155'")).firstMatch
        if h155.exists {
            h155.tap()
            XCTAssertTrue(app.navigationBars["H-155"].waitForExistence(timeout: 15), "Tap on H-155 did not open it")
        }
    }
}
