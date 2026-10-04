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

    static func launch(_ extra: [String] = [], dark: Bool = false) throws -> XCUIApplication {
        let token = try XCTUnwrap(token, "No demo token: run scripts/ui-tests.sh, or start `python3 demo/make_demo.py --serve --peer-port 49791`")
        XCUIDevice.shared.appearance = dark ? .dark : .light
        let app = XCUIApplication()
        app.launchArguments = ["-gravHost", "127.0.0.1", "-gravPort", environment["GRAV_PORT"] ?? "49790",
                               "-lensPort", environment["LENS_PORT"] ?? "49788", "-gravToken", token] + extra
        app.launch()
        return app
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

    @discardableResult
    func waitFor(_ element: XCUIElement, _ timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing: \(element)", file: file, line: line)
        return element
    }
}

extension XCUIApplication {
    func tab(_ name: String) {
        tabBars.buttons[name].tap()
    }

    /// Scrolls the current list until `element` is hittable.
    func scroll(to element: XCUIElement, max: Int = 12) {
        var tries = 0
        while !(element.exists && element.isHittable), tries < max {
            swipeUp()
            tries += 1
        }
    }
}
