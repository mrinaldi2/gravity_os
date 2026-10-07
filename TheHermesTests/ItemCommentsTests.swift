import SwiftProtobuf
import XCTest
@testable import TheHermes

/// H-202: a posted comment shows at once and is then confirmed, or fails
/// with a retry; replies sit under their comment; older services that send no
/// comment text still show that a comment is there.
final class ItemCommentsTests: XCTestCase {
    private func comment(_ id: String, _ author: String, _ body: String, replyTo: String? = nil, at: Int64 = 1) -> Hermes_Board_V1_ItemComment {
        var c = Hermes_Board_V1_ItemComment()
        c.id = id
        c.author = author
        c.body = body
        if let replyTo { c.replyTo = replyTo }
        c.at = Google_Protobuf_Timestamp(seconds: at)
        return c
    }

    func testAPostedCommentShowsAtOnceAsSending() {
        let posted = PendingComment(body: "Ship it after the fix", replyTo: nil)
        let rows = CommentThread.rows(comments: [], history: [], pending: [posted])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].status, CommentRow.Status.sending)
        XCTAssertEqual(rows[0].body, "Ship it after the fix")
        XCTAssertEqual(rows[0].pendingId, posted.id)
    }

    func testAConfirmedCommentIsReplacedByTheBoardsCopy() {
        var posted = PendingComment(body: "Looks good", replyTo: nil)
        posted.state = .sent
        let board = [comment("c1", "device:phone", "Looks good")]
        let rows = CommentThread.rows(comments: board, history: [], pending: [posted])
        XCTAssertEqual(rows.map(\.id), ["c1"], "no duplicate once the board echoes it")
        XCTAssertEqual(rows[0].status, .onBoard)
        XCTAssertTrue(CommentThread.stillPending([posted], comments: board).isEmpty)
    }

    func testAConfirmedCommentStaysPostedWhenTheBoardSendsNoText() {
        var posted = PendingComment(body: "Looks good", replyTo: nil)
        posted.state = .sent
        let rows = CommentThread.rows(comments: [comment("c1", "user", "")], history: [], pending: [posted])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1].status, .sent, "older service: our copy stays, marked Posted")
        XCTAssertNil(rows[0].body)
        XCTAssertEqual(CommentThread.stillPending([posted], comments: [comment("c1", "user", "")]).count, 1)
    }

    func testAFailedCommentKeepsItsTextAndReason() {
        var posted = PendingComment(body: "Hold this one", replyTo: nil)
        posted.state = .failed("Not connected to the Hermes service.")
        let rows = CommentThread.rows(comments: [], history: [], pending: [posted])
        XCTAssertEqual(rows[0].status, .failed("Not connected to the Hermes service."))
        XCTAssertEqual(rows[0].body, "Hold this one")
        XCTAssertEqual(CommentThread.stillPending([posted], comments: []).count, 1, "kept for Retry")
    }

    func testRepliesSitUnderTheirComment() {
        let board = [comment("c1", "bot:dev", "Which build?"),
                     comment("c2", "user", "The 0.17.4 one", replyTo: "c1", at: 2),
                     comment("c3", "bot:qa", "Verified", at: 3)]
        let groups = CommentThread.grouped(CommentThread.rows(comments: board, history: [], pending: []))
        XCTAssertEqual(groups.map(\.id), ["c1", "c3"])
        XCTAssertEqual(groups[0].replies.map(\.id), ["c2"])
    }

    func testAReplyToAnUnknownCommentStaysVisible() {
        let rows = CommentThread.rows(comments: [comment("c2", "user", "Yes", replyTo: "gone")], history: [], pending: [])
        XCTAssertEqual(CommentThread.grouped(rows).map(\.id), ["c2"])
    }

    func testAnOlderServiceWithoutCommentsShowsTheCommentedEvents() {
        var event = Hermes_Board_V1_ItemEvent()
        event.id = 7
        event.kind = .commented
        event.actor = "bot:dev"
        event.to = "c9"
        var moved = Hermes_Board_V1_ItemEvent()
        moved.kind = .moved
        let rows = CommentThread.rows(comments: [], history: [event, moved], pending: [])
        XCTAssertEqual(rows.map(\.id), ["c9"])
        XCTAssertNil(rows[0].body)
        XCTAssertEqual(rows[0].author, "bot:dev")
    }

    func testAnUnknownAuthorIsABotNeverAnId() {
        let names = ["dev": "Desktop Dev"]
        XCTAssertEqual(CommentWords.author("bot:dev") { names[$0] }, "Desktop Dev")
        XCTAssertEqual(CommentWords.author("bot:3f2a9c10-aaaa-bbbb-cccc-0123456789ab") { names[$0] }, "A bot")
        XCTAssertEqual(CommentWords.author("device:phone") { names[$0] }, "You")
        XCTAssertEqual(CommentWords.author("user") { names[$0] }, "You")
    }

    func testReplyingToYourOwnComment() {
        XCTAssertEqual(CommentWords.replying(to: "user") { _ in "You" }, "Replying to your comment")
        XCTAssertEqual(CommentWords.replying(to: "bot:dev") { _ in "Desktop Dev" }, "Replying to Desktop Dev")
    }
}
