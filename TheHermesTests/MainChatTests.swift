import SwiftProtobuf
import XCTest
@testable import TheHermes

/// The main chat lists one thread per bot across computers (H-128 D6).
final class MainChatTests: XCTestCase {
    private func thread(_ bot: String, daemon: String, name: String, text: String, at: Int64,
                        unread: UInt32 = 0, question: Bool = false) -> Hermes_Home_V1_OwnerThread {
        var t = Hermes_Home_V1_OwnerThread()
        t.bot.botID = bot
        t.bot.daemonID = daemon
        t.bot.name = name
        t.projectID = "p1"
        t.last.text = text
        t.last.at = Google_Protobuf_Timestamp(seconds: at)
        t.unread = unread
        t.openQuestion = question
        return t
    }

    func testALinkedBotIsListedOnceFromItsOwnComputer() {
        let standIn = thread("b9", daemon: "d-win", name: "Tester Win", text: "relayed", at: 10)
        let own = thread("b9", daemon: "d-win", name: "Tester Win", text: "own", at: 10, unread: 2)
        let cards = ThreadMerge.merge([("mac", "d-mac", [standIn]), ("win", "d-win", [own])])
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.computerId, "win")
        XCTAssertEqual(cards.first?.unread, 2)
    }

    func testAStandInIsKeptWhenItsComputerIsNotConnected() {
        let standIn = thread("b9", daemon: "d-win", name: "Tester Win", text: "relayed", at: 10)
        let cards = ThreadMerge.merge([("mac", "d-mac", [standIn])])
        XCTAssertEqual(cards.map(\.computerId), ["mac"])
    }

    func testQuestionsThenUnreadThenNewest() {
        let cards = ThreadMerge.merge([("mac", "d-mac", [
            thread("a", daemon: "d-mac", name: "A", text: "old read", at: 1),
            thread("b", daemon: "d-mac", name: "B", text: "new read", at: 50),
            thread("c", daemon: "d-mac", name: "C", text: "unread", at: 5, unread: 1),
            thread("d", daemon: "d-mac", name: "D", text: "asks", at: 2, question: true),
        ])])
        XCTAssertEqual(cards.map(\.botName), ["D", "C", "B", "A"])
    }
}
