import XCTest
@testable import GravitiOS

/// Bots' permission prompts, against frames shaped as Gravity's
/// docs/protocol.md describes them.
@MainActor
final class PermissionsTests: XCTestCase {
    private func row(_ id: String, bot: String = "b1", created: String = "2026-10-02T09:00:00Z") -> JSONDict {
        ["id": id, "bot_id": bot, "tool": "Bash", "summary": "Bash: rm -rf build/",
         "input": "{\n  \"command\": \"rm -rf build/\"\n}", "created_at": created,
         "expires_at": "2026-10-02T09:10:00Z"]
    }

    private func store() -> AppStore {
        let store = AppStore(defaults: ComputerDefaults(id: "test-permissions"))
        store.capabilities = ["permissions"]
        // Seen as on screen, so the test posts no notification.
        store.botOnScreen = "b1"
        return store
    }

    func testDecodesARequest() {
        let request = PermissionRequest(row("p1"))
        XCTAssertEqual(request.id, "p1")
        XCTAssertEqual(request.botId, "b1")
        XCTAssertEqual(request.tool, "Bash")
        XCTAssertEqual(request.summary, "Bash: rm -rf build/")
        XCTAssertTrue(request.input.contains("\"command\""))
        XCTAssertNotNil(request.createdAt)
        XCTAssertEqual(request.expiresAt.map { $0.timeIntervalSince(request.createdAt!) }, 600)
    }

    func testDecodesWithMissingFields() {
        let request = PermissionRequest(["id": "p2", "bot_id": "b1"])
        XCTAssertEqual(request.summary, "")
        XCTAssertEqual(request.input, "")
        XCTAssertNil(request.expiresAt)
    }

    func testCardsArriveOldestFirstAndLeaveWhenResolved() {
        let store = store()
        store.pushReceived("permission_request", ["request": row("late", created: "2026-10-02T09:05:00Z")])
        store.pushReceived("permission_request", ["request": row("early", created: "2026-10-02T09:01:00Z")])
        XCTAssertEqual(store.permissions.map(\.id), ["early", "late"], "oldest first")

        // The same prompt pushed again stays one card.
        store.pushReceived("permission_request", ["request": row("early", created: "2026-10-02T09:01:00Z")])
        XCTAssertEqual(store.permissions.count, 2)

        store.pushReceived("permission_resolved", ["request_id": "early", "bot_id": "b1", "outcome": "allowed_once"])
        XCTAssertEqual(store.permissions.map(\.id), ["late"])
        store.pushReceived("permission_resolved", ["request_id": "late", "bot_id": "b1", "outcome": "expired"])
        XCTAssertTrue(store.permissions.isEmpty)

        // A prompt this phone never saw resolving changes nothing.
        store.pushReceived("permission_resolved", ["request_id": "unknown", "bot_id": "b1", "outcome": "abandoned"])
        XCTAssertTrue(store.permissions.isEmpty)
    }

    func testPromptsCountAsUrgentAndFilterByBot() {
        let store = store()
        store.pushReceived("permission_request", ["request": row("a", bot: "b1")])
        store.pushReceived("permission_request", ["request": row("b", bot: "b2")])
        XCTAssertEqual(store.decisionsBadge, 2, "waiting prompts count in the Decisions badge")
        XCTAssertEqual(store.permissions(for: "b2").map(\.id), ["b"])
    }

    func testTheAppSaysItAnswersPrompts() {
        XCTAssertTrue(DaemonClient.features.contains("permission_cards"))
    }

    func testAnswersAreTheProtocolsWords() {
        XCTAssertEqual(PermissionRequest.Answer.allCases.map(\.rawValue), ["allow_once", "allow_session", "deny"])
    }
}
