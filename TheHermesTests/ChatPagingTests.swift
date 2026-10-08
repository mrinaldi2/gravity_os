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
}
