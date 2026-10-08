import XCTest

/// H-216: a thehermes://item link opened while the app is closed is kept until the
/// projects load, then opens its card; an id no project uses says so.
final class H216Tests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        if UIDevice.current.userInterfaceIdiom == .pad { throw XCTSkip("iPhone layout") }
    }

    /// The demo app, not running: a link launches it, with the demo arguments.
    private func closedApp() throws -> XCUIApplication {
        let token = try XCTUnwrap(DemoApp.token, "No demo token: run scripts/ui-tests.sh")
        let app = XCUIApplication()
        app.launchArguments = ["-gravHost", "127.0.0.1", "-gravPort", DemoApp.environment["GRAV_PORT"] ?? "49790",
                               "-lensPort", DemoApp.environment["LENS_PORT"] ?? "49788", "-gravToken", token,
                               "-noNotificationPrompt", "YES"]
        app.terminate()
        return app
    }

    func testColdLinkToAnUnknownIdSaysNotFound() throws {
        let app = try closedApp()
        app.open(URL(string: "thehermes://item/ZZ-404")!)
        let alert = app.alerts["ZZ-404"]
        XCTAssertTrue(alert.waitForExistence(timeout: 30), "The link did nothing")
        XCTAssertTrue(alert.staticTexts["ZZ-404 isn't on the board. It may have been deleted or mistyped."].exists)
        screenshot("H-216-cold-link-unknown")
        alert.buttons["OK"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
    }

    /// Needs the demo's control port (a project with a board and cards).
    func testColdLinkOpensTheCard() throws {
        guard let port = DemoApp.environment["DEMO_CONTROL_PORT"], !port.isEmpty else {
            throw XCTSkip("No DEMO_CONTROL_PORT: the demo can't make a board")
        }
        _ = try post(port, "/lab")
        // board_get creates the board for the owner; then the cards can be filed.
        let app = try closedApp()
        app.launchArguments += ["-openProject", "Hermes Lab", "-openSegment", "board"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Hermes Lab"].waitForExistence(timeout: 30))
        sleep(3)
        let items = try post(port, "/items")
        let id = try XCTUnwrap(Self.itemId(in: items), "No card id in \(items)")

        app.terminate()
        app.launchArguments.removeLast(4)
        app.open(URL(string: "thehermes://item/\(id)")!)
        XCTAssertTrue(app.navigationBars[id].waitForExistence(timeout: 30), "The link to \(id) was dropped")
        screenshot("H-216-cold-link-card")
    }

    /// The first "ABC-12" id anywhere in a reply.
    private static func itemId(in value: Any) -> String? {
        if let text = value as? String, text.range(of: "^[A-Z]+-[0-9]+$", options: .regularExpression) != nil { return text }
        if let dict = value as? [String: Any] {
            if let id = dict["id"].flatMap({ itemId(in: $0) }) { return id }
            for (_, inner) in dict.sorted(by: { $0.key < $1.key }) { if let id = itemId(in: inner) { return id } }
        }
        if let list = value as? [Any] { for inner in list { if let id = itemId(in: inner) { return id } } }
        return nil
    }

    private func post(_ port: String, _ path: String) throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        var result: [String: Any]?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            result = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            done.signal()
        }.resume()
        done.wait()
        return try XCTUnwrap(result, "The demo's \(path) did not answer")
    }
}
