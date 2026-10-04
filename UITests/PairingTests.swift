import XCTest

/// H-010 and H-011: pairing from a pasted link, verified before it is saved, and a
/// thehermes:// link from outside the app that fills Connect without adding anything.
final class PairingTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func link(host: String = "127.0.0.1", port: String? = nil, token: String) -> String {
        let port = port ?? DemoApp.environment["GRAV_PORT"] ?? "49790"
        let token = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? token
        return "thehermes://pair?host=\(host)&port=\(port)&token=\(token)&name=Demo%20Mac&kind=mac"
    }

    /// iOS asks once before the app reads the clipboard.
    private func allowPaste(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for alerts in [app.alerts, springboard.alerts] {
            let allow = alerts.buttons["Allow Paste"]
            if allow.waitForExistence(timeout: 3) { allow.tap(); return }
        }
    }

    private func paste(_ text: String, in app: XCUIApplication) {
        UIPasteboard.general.string = text
        waitFor(app.buttons["Paste pairing link"]).tap()
        allowPaste(app)
    }

    func testPasteLinkConnectingErrorsThenSuccess() throws {
        let token = try XCTUnwrap(DemoApp.token)
        let app = DemoApp.launchFirstRun()
        waitFor(app.navigationBars["Connect to The Hermes"])
        screenshot("QA-002-pairing-first-run")

        // Not a link: a warning, nothing tried.
        paste("hello there", in: app)
        waitFor(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'That isn’t a pairing link'")).firstMatch)

        // A service that never answers: Connecting… for the whole wait, then the address error.
        paste(link(host: "10.255.255.1", port: "49777", token: token), in: app)
        waitFor(app.staticTexts["Connecting to Demo Mac…"], 5)
        screenshot("QA-002-pairing-connecting")
        waitFor(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Couldn’t reach 10.255.255.1:49777'")).firstMatch, 25)
        screenshot("QA-002-pairing-unreachable")

        // A wrong token: rejected, said next to the token field, nothing saved.
        paste(link(token: "not-the-token"), in: app)
        waitFor(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Token rejected'")).firstMatch)
        XCTAssertTrue(app.secureTextFields["Device token"].exists, "The token field is not shown with the error")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "A rejected computer opened the app")
        screenshot("QA-002-pairing-bad-token")

        // The right link: connected, saved, and the app opens on Home.
        paste(link(token: token), in: app)
        waitFor(app.tabBars.buttons["Home"], 20)
        // After pairing, a word on notifications before iOS asks.
        let explainer = app.staticTexts["Get told when a bot needs you"]
        if explainer.waitForExistence(timeout: 5) {
            screenshot("QA-002-pairing-explainer")
            app.buttons["Not now"].tap()
        }
        waitFor(app.buttons["Computer: Demo Mac"])
        screenshot("QA-002-pairing-success")
    }

    func testOpenedLinkFillsConnectWithoutAdding() throws {
        let token = try XCTUnwrap(DemoApp.token)
        let app = DemoApp.launchFirstRun()
        waitFor(app.navigationBars["Connect to The Hermes"])
        open(link(token: token), in: app)
        waitFor(app.staticTexts["Opened from a pairing link. Check the computer and its address, then tap Connect."])
        let host = app.textFields["Tailscale name or 100.x.y.z"]
        XCTAssertEqual(host.value as? String, "127.0.0.1")
        XCTAssertEqual(app.textFields["Port"].value as? String, DemoApp.environment["GRAV_PORT"] ?? "49790")
        XCTAssertEqual(app.textFields["Name (Mac)"].value as? String, "Demo Mac")
        screenshot("QA-002-deeplink-prefilled")
        // It waits for Connect: nothing is tried or added on its own.
        sleep(4)
        XCTAssertFalse(app.staticTexts["Connecting to Demo Mac…"].exists, "The link started connecting on its own")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "The link added the computer on its own")
        let connect = app.buttons["Connect"]
        app.scroll(to: connect)
        connect.tap()
        waitFor(app.tabBars.buttons["Home"], 20)
    }

    func testOpenedLinkWithAComputerOpensAddSheet() throws {
        let token = try XCTUnwrap(DemoApp.token)
        let app = try DemoApp.launch()
        allowSystemAlerts()
        waitFor(app.tabBars.buttons["Home"])
        open(link(token: token).replacingOccurrences(of: "Demo%20Mac", with: "Second%20Mac"), in: app)
        waitFor(app.navigationBars["Add a computer"])
        waitFor(app.staticTexts["Opened from a pairing link. Check the computer and its address, then tap Connect."])
        sleep(3)
        XCTAssertFalse(app.staticTexts["Connecting to Second Mac…"].exists, "The link started connecting on its own")
        screenshot("QA-002-deeplink-add-sheet")
        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.buttons["Computer: Second Mac"].exists)
    }

    /// The system's "Open in “The Hermes”?" is confirmed when it shows.
    private func open(_ link: String, in app: XCUIApplication) {
        app.open(URL(string: link)!)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 3) { open.tap() }
    }
}
