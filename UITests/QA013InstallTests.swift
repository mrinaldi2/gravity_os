import XCTest

/// H-230 (UX-043/UX-047) on the demo world. The release-based install states need a
/// package with a published iOS build, which the demo can't make without owner powers
/// (board start, DevOps role, approval, a paired device): see the QA-013 report. What
/// runs here: the "Updated to…" toast, once per new version.
final class QA013InstallTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func toast(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Updated to The Hermes'")).firstMatch
    }

    func testUpdatedToastShowsOnceAfterAnUpdate() throws {
        // As if the last launch ran an older version (the argument domain wins over the
        // app's own defaults for this launch only).
        let app = try DemoApp.launch(["-lastLaunchedVersion", "0.0.1 (1)"])
        allowSystemAlerts()
        XCTAssertTrue(toast(app).waitForExistence(timeout: 8), "No 'Updated to…' toast after an update")
        screenshot("QA-013-08-updated-toast")
        XCTAssertTrue(toast(app).waitForNonExistence(timeout: 8), "The toast stayed")
        app.terminate()

        // The next launch of the same version says nothing.
        let again = try DemoApp.launch()
        allowSystemAlerts()
        XCTAssertFalse(toast(again).waitForExistence(timeout: 6), "The toast showed again for the same version")
        screenshot("QA-013-08-no-toast-on-relaunch")
    }
}
