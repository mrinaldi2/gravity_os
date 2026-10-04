import XCTest

/// R1-I1: the display name is "The Hermes", and the main screens use the glossary's
/// words, with none of the retired ones.
final class GlossaryTests: XCTestCase {
    /// Words the glossary retired, as they would show on screen.
    static let retired = ["Gravity", "gravityd", "GravitiOS", "Permission prompts", "Waiting on you",
                          "Answer and publish", "Hold for later", "Restart session", "Clear chat",
                          "Reports", "Runtime", "Grants", "Delivery backlog", "Auth failed",
                          "Version mismatch", "Something went wrong", "Retry", "Between bots",
                          "Charter", "Standing instructions", "Note from Gravity", "Allow for this session",
                          "decisions waiting", "decision waiting"]
    /// Allowed although they contain a retired word: the About attribution, and the
    /// config path that stays until R2.
    static let allowed = ["Based on Gravity by", "gravityd.toml"]

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        try DemoControl.ensurePermissionPrompts() // "Allow for session" is on their cards
        app = try DemoApp.launch()
        allowSystemAlerts()
        waitFor(app.tabBars.buttons["Home"])
    }

    func testDisplayName() {
        XCTAssertEqual(app.label, "The Hermes")
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let icon = springboard.icons["The Hermes"]
        XCTAssertTrue(icon.waitForExistence(timeout: 5), "No home-screen icon named The Hermes")
        screenshot("QA-002-display-name")
        app.activate()
    }

    func testMainScreensUseTheGlossary() {
        var seen: Set<String> = []
        func look(_ screen: String) {
            sleep(1)
            let words = app.visibleWords
            seen.formUnion(words)
            for word in words {
                let text = Self.allowed.reduce(word) { $0.replacingOccurrences(of: $1, with: "") }
                for old in Self.retired where text.range(of: "\\b\(old)\\b", options: .regularExpression) != nil {
                    XCTFail("\(screen): retired word \"\(old)\" in \"\(word)\"")
                }
            }
            screenshot("QA-002-glossary-\(screen)")
        }

        look("home")
        app.tab("Decisions")
        waitFor(app.staticTexts["Permission requests"])
        look("decisions")
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Resolve conflicts automatically or always ask?'")).firstMatch
        app.scroll(to: row)
        row.tap()
        waitFor(app.navigationBars["Decision"])
        app.scroll(to: app.buttons["Put on hold"])
        XCTAssertTrue(app.buttons["Publish ruling"].exists)
        XCTAssertTrue(app.buttons["Put on hold"].exists)
        look("decision-detail")

        app.tab("Bots")
        look("bots")
        waitFor(app.botRow("Architect")).tap()
        for pane in ["Chat", "Work", "Artifacts", "More"] {
            XCTAssertTrue(waitFor(app.buttons[pane]).exists, "Pane \(pane)")
        }
        app.buttons["More"].tap()
        app.scroll(to: app.buttons["Clear conversation"])
        XCTAssertTrue(app.buttons["Restart bot"].exists)
        XCTAssertTrue(app.buttons["Clear conversation"].exists)
        look("bot-more")

        app.tab("Files")
        look("files")
        app.tab("Computers")
        look("computers")
        app.buttons.containing(NSPredicate(format: "label CONTAINS 'Demo Mac'")).firstMatch.tap()
        sleep(2)
        look("computer")
        let service = app.labelled("Hermes service")
        app.scroll(to: service)
        look("computer-service")
        XCTAssertTrue(seen.contains { $0.contains("Hermes service") }, "\"Hermes service\" not on the computer page")
        XCTAssertTrue(seen.contains("Allow for session"), "No Allow for session answer on a permission card")
        XCTAssertTrue(seen.contains { $0.hasPrefix("Needs you") || $0.contains("need you") || $0.contains("needs you") },
                      "\"Needs you\" not on Home")
    }
}
