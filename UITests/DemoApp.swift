import XCTest

/// The app pointed at the demo world (`demo/make_demo.py`), through the Debug-only
/// launch arguments in `Computers.debugComputers()`. `scripts/ui-tests.sh` starts the
/// demo and passes its token as `TEST_RUNNER_GRAV_TOKEN`; without it the token is read
/// from the demo folder, so the tests also run from Xcode while the demo is serving.
enum DemoApp {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static var token: String? {
        if let token = environment["GRAV_TOKEN"], !token.isEmpty { return token }
        let path = (environment["GRAV_DEMO_DIR"] ?? "/tmp/gravitios-demo") + "/gravity/secrets/client.token"
        return (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var decisionId: String? { environment["DEMO_DECISION_ID"].flatMap { $0.isEmpty ? nil : $0 } }
    static var botId: String? { environment["DEMO_BOT_ID"].flatMap { $0.isEmpty ? nil : $0 } }

    /// The app with no computer: no demo arguments, and an empty saved list
    /// (the argument domain hides what an earlier pairing saved).
    static func launchFirstRun(_ extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.appearance = .light
        let app = XCUIApplication()
        app.launchArguments = ["-computers", "<>", "-selectedComputer", ""] + extra
        app.launch()
        return app
    }

    static func launch(_ extra: [String] = [], dark: Bool = false) throws -> XCUIApplication {
        let token = try XCTUnwrap(token, "No demo token: run scripts/ui-tests.sh, or start `python3 demo/make_demo.py --serve --peer-port 49791`")
        let app = XCUIApplication()
        app.launchArguments = ["-gravHost", "127.0.0.1", "-gravPort", environment["GRAV_PORT"] ?? "49790",
                               "-lensPort", environment["LENS_PORT"] ?? "49788", "-gravToken", token] + extra
        // A freshly erased simulator can ignore the first appearance change, which
        // once let "dark" checks measure light mode: the screen must show it.
        for _ in 0..<3 {
            XCUIDevice.shared.appearance = dark ? .dark : .light
            app.launch()
            sleep(2)
            if isDark(app) == dark { return app }
            app.terminate()
            sleep(1)
        }
        XCTFail("The simulator would not switch to \(dark ? "dark" : "light") mode")
        return app
    }

    /// The screen's most common colour is dark.
    static func isDark(_ app: XCUIApplication) -> Bool {
        Contrast(of: app).background.luminance < 0.2
    }
}

extension XCTestCase {
    /// The notifications prompt the app asks for on first launch.
    func allowSystemAlerts() {
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Don’t Allow"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
    }

    /// Kept in the result bundle, and written as `<name>.png` to `SCREENSHOT_DIR` when set.
    func screenshot(_ name: String, of element: XCUIScreenshotProviding = XCUIScreen.main) {
        let shot = element.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = DemoApp.environment["SCREENSHOT_DIR"], !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    /// Waits for `element`; when it never comes, the screen and its element tree go in the report.
    @discardableResult
    func waitFor(_ element: XCUIElement, _ timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        if !element.waitForExistence(timeout: timeout) {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "missing element"
            shot.lifetime = .keepAlways
            add(shot)
            let tree = XCTAttachment(string: XCUIApplication().debugDescription)
            tree.name = "element tree"
            tree.lifetime = .keepAlways
            add(tree)
            XCTFail("Missing: \(element)", file: file, line: line)
        }
        return element
    }
}

extension XCUIApplication {
    /// Taps a tab; from a pushed screen, whose tab bar can be hidden, goes back first.
    func tab(_ name: String) {
        var tries = 0
        while !(tabBars.buttons[name].exists && tabBars.buttons[name].isHittable), tries < 4 {
            let back = navigationBars.buttons.element(boundBy: 0)
            if back.exists { back.tap() } else { swipeDown() }
            tries += 1
        }
        tabBars.buttons[name].tap()
    }

    /// A bot's row in Bots, scrolled into view.
    func botRow(_ name: String) -> XCUIElement {
        let row = buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "\(name), ", "Unread, \(name), ")).firstMatch
        scroll(to: row)
        return row
    }

    /// Any element whose label is `label`: combined rows are not always StaticText.
    func labelled(_ label: String) -> XCUIElement {
        descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// Scrolls the current list until `element` is hittable: down first, then back up.
    func scroll(to element: XCUIElement, max: Int = 10) {
        var tries = 0
        while !(element.exists && element.isHittable), tries < max {
            swipeUp()
            tries += 1
        }
        tries = 0
        while !(element.exists && element.isHittable), tries < max {
            swipeDown()
            tries += 1
        }
    }

    /// Every label and value on screen, from the element tree (fast, unlike querying each element).
    var visibleWords: [String] {
        let tree = debugDescription
        let pattern = try! NSRegularExpression(pattern: "(?:label|value|identifier): '([^']*)'")
        return pattern.matches(in: tree, range: NSRange(tree.startIndex..., in: tree)).compactMap {
            Range($0.range(at: 1), in: tree).map { String(tree[$0]) }
        }
    }
}
