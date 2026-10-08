import XCTest

/// H-172 AC1 (iOS half): bots waiting_for_approval on their own terminal prompt are rows on
/// Needs you against a 0.17 daemon, titled "<bot> needs approval" or with a masked summary,
/// never a secret. Needs the two waits posted first (QA tools/approval_waits.py): Architect
/// bare, Designer with a fake secret (QA172s3cr3t) in its tool input. QA015=1 runs it.
final class QA015ApprovalRowTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        if (DemoApp.environment["QA015"] ?? "").isEmpty { throw XCTSkip("Needs the approval waits (QA015)") }
        if UIDevice.current.userInterfaceIdiom == .pad { throw XCTSkip("iPhone capture") }
    }

    func testWaitingForApprovalRowsOnNeedsYou() throws {
        let app = try DemoApp.launch(["-noNotificationPrompt", "YES"])
        allowSystemAlerts()
        app.tab("Needs you")
        let architect = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Architect needs approval'")).firstMatch
        if !architect.waitForExistence(timeout: 30) { app.scroll(to: architect) }
        XCTAssertTrue(architect.exists, "No 'Architect needs approval' row")
        app.scroll(to: architect)
        screenshot("QA-015-h172-architect-needs-approval")

        let designer = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Designer'")).firstMatch
        app.scroll(to: designer)
        XCTAssertTrue(designer.exists, "No Designer row")
        XCTContext.runActivity(named: "Designer row: \(designer.label)") { _ in }
        print("QA-015 Designer row: \(designer.label)")
        screenshot("QA-015-h172-designer-masked")

        // No secret anywhere on the screen.
        let words = app.visibleWords.joined(separator: " | ")
        XCTAssertFalse(words.contains("QA172s3cr3t"), "The secret is on Needs you")
        XCTAssertFalse(words.contains("sk-live"), "The secret's prefix is on Needs you")
    }
}
