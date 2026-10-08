import XCTest

/// H-228: a long step group in the open turn is expanded; when the turn ends it folds
/// to its summary, and the transcript around it stays put. The test writes iOS Dev's
/// demo transcript itself (DEMO_OUT, as scripts/ui-tests.sh passes it): eight commands
/// into the open turn, then the turn's end.
final class QA012StepFoldTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        if UIDevice.current.userInterfaceIdiom == .pad { throw XCTSkip("iPhone layout") }
        if (DemoApp.environment["DEMO_OUT"] ?? "").isEmpty { throw XCTSkip("No DEMO_OUT: run scripts/ui-tests.sh") }
        app = try DemoApp.launch()
        allowSystemAlerts()
    }

    private func any(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
    }

    /// iOS Dev's transcript in the demo (the one with its conflict-banner turn).
    private func transcript() throws -> URL {
        let projects = URL(fileURLWithPath: DemoApp.environment["DEMO_OUT"]!).appendingPathComponent("user-home/.claude/projects")
        let folders = try FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)
        for folder in folders where folder.lastPathComponent.hasSuffix("bots-ios-dev-workspace") {
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            where file.pathExtension == "jsonl" { return file }
        }
        throw XCTSkip("No iOS Dev transcript under \(projects.path)")
    }

    private func append(_ records: [[String: Any]]) throws {
        let handle = try FileHandle(forWritingTo: try transcript())
        handle.seekToEndOfFile()
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for var record in records {
            record["uuid"] = UUID().uuidString.lowercased()
            record["timestamp"] = stamp.string(from: Date())
            handle.write(try JSONSerialization.data(withJSONObject: record))
            handle.write("\n".data(using: .utf8)!)
        }
        try handle.close()
    }

    private func command(_ number: Int) -> [[String: Any]] {
        let id = "toolu_qa012\(number)\(Int(Date().timeIntervalSince1970))"
        return [["type": "assistant", "message": ["role": "assistant", "content": [
                    ["type": "tool_use", "id": id, "name": "Bash",
                     "input": ["command": "swift test --filter Fold\(number)", "description": "Fold check \(number)"]]]]],
                ["type": "user", "message": ["role": "user", "content": [
                    ["type": "tool_result", "tool_use_id": id, "content": "ok"]]],
                 "toolUseResult": ["stdout": "ok", "stderr": "", "interrupted": false]]]
    }

    func testLongStepGroupFoldsWhenItsTurnEnds() throws {
        app.openBot("iOS Dev")
        waitFor(app.pane("Chat")).tap()
        waitFor(any("Run the UI tests"), 20)

        // Eight more commands in the open turn: a long group, shown expanded while it runs.
        try append((1...8).flatMap(command))
        let last = any("Fold check 8")
        XCTAssertTrue(last.waitForExistence(timeout: 20), "The new steps did not reach the chat")
        app.scroll(to: last)
        let group = any(" steps")
        XCTAssertTrue(group.exists, "No step group summary")
        screenshot("QA-012-steps-open")

        // The turn ends: the group folds to its summary, the transcript keeps its place.
        try append([["type": "assistant", "message": ["role": "assistant", "content": [
                        ["type": "text", "text": "Fold checks done; all eight pass."]]]],
                    ["type": "system", "subtype": "turn_duration", "durationMs": 64000]])
        XCTAssertTrue(any("Fold checks done").waitForExistence(timeout: 20), "The turn's end did not reach the chat")
        sleep(2)
        app.scroll(to: any("Fold checks done"))
        screenshot("QA-012-steps-folded")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH '9 steps' OR label BEGINSWITH '10 steps'")).firstMatch.exists,
                      "The folded group does not show its step count")
        XCTAssertFalse(any("Fold check 5").isHittable, "The long group did not fold when its turn ended")
        XCTAssertEqual(app.state, .runningForeground)
    }
}
