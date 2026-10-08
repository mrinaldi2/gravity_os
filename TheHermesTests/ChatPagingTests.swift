import XCTest
@testable import TheHermes

/// H-228: the phone's chat holds the newest page and up to 5 earlier ones.
final class ChatPagingTests: XCTestCase {
    func testEarlierPagesStopAfterFive() {
        XCTAssertTrue(ChatPaging.canLoadEarlier(loaded: Page.turns, hasMore: true), "1 page: more on offer")
        XCTAssertTrue(ChatPaging.canLoadEarlier(loaded: Page.turns * 5, hasMore: true))
        XCTAssertFalse(ChatPaging.canLoadEarlier(loaded: Page.turns * 6, hasMore: true), "newest + 5 earlier: capped")
        XCTAssertFalse(ChatPaging.canLoadEarlier(loaded: 3, hasMore: false), "nothing older")
    }

    func testLiveTurnsPastTheCapPushTheOldestOut() {
        // S1: the cap holds as live turns arrive, not only for loaded pages.
        let full = Array(0..<ChatPaging.cap)
        XCTAssertFalse(ChatPaging.trimmed(full).dropped)
        let (kept, dropped) = ChatPaging.trimmed(full + [ChatPaging.cap, ChatPaging.cap + 1])
        XCTAssertTrue(dropped)
        XCTAssertEqual(kept.count, ChatPaging.cap)
        XCTAssertEqual(kept.first, 2, "the oldest go")
        XCTAssertEqual(kept.last, ChatPaging.cap + 1, "the newest stay")
        // An earlier page only asks for what is left under the cap.
        XCTAssertEqual(ChatPaging.earlierLimit(loaded: Page.turns), Page.turns)
        XCTAssertEqual(ChatPaging.earlierLimit(loaded: ChatPaging.cap - 4), 4)
        XCTAssertEqual(ChatPaging.earlierLimit(loaded: ChatPaging.cap), 0)
    }

    @MainActor
    func testAStepGroupKeepsWhatTheOwnerChoseAcrossRows() {
        // S2: kept by the pane, so a turn moving from the drawn tail into the lazy stack keeps it.
        let expansions = StepExpansions()
        XCTAssertFalse(expansions.isExpanded("t1#s1", default: false))
        let first = expansions.binding("t1#s1", default: false)
        first.wrappedValue = true
        // The row is rebuilt elsewhere: a new binding for the same group.
        XCTAssertTrue(expansions.binding("t1#s1", default: false).wrappedValue)
        XCTAssertTrue(expansions.isExpanded("t2#s1", default: true), "untouched groups keep their default")
    }

    func testTheCapSaysWhereTheRestIs() {
        XCTAssertEqual(ChatPaging.capped(computer: "Studio Mac", bot: "iOS Dev"),
                       "Earlier activity is on Studio Mac. Open iOS Dev in The Hermes app there to see all of it.")
        XCTAssertEqual(ChatPaging.capped(computer: "", bot: "iOS Dev"),
                       "Earlier activity is on its computer. Open iOS Dev in The Hermes app there to see all of it.")
    }
}
