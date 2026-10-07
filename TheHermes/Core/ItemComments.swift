import Foundation

/// A card's comments as the owner sees them (H-202): what the board holds,
/// plus what this device just posted, shown at once and then confirmed, or
/// failed with a retry. Replies sit under the comment they answer.

/// A comment this device is posting, or posted and the board doesn't echo yet.
struct PendingComment: Identifiable, Equatable {
    enum State: Equatable {
        case sending
        /// The board took it (its `edited` answer).
        case sent
        case failed(String)
    }

    let id: UUID
    let body: String
    let replyTo: String?
    var state: State
    let at: Date

    init(body: String, replyTo: String?, at: Date = Date()) {
        id = UUID()
        self.body = body
        self.replyTo = replyTo
        state = .sending
        self.at = at
    }
}

/// One row: a comment from the board, or one of ours.
struct CommentRow: Identifiable, Equatable {
    enum Status: Equatable {
        case onBoard
        case sending
        case sent
        case failed(String)
    }

    let id: String
    /// The actor as stored (`user`, `bot:<id>`, `device:<id>`); "owner" for ours.
    let author: String
    /// Nil when an older service sends the comment without its text.
    let body: String?
    let at: Date?
    let replyTo: String?
    let status: Status
    /// Set on our own rows, to retry them.
    let pendingId: UUID?
}

/// A comment with the replies that answer it, oldest first.
struct CommentGroup: Identifiable, Equatable {
    let comment: CommentRow
    let replies: [CommentRow]
    var id: String { comment.id }
}

enum CommentThread {
    private static func isOwner(_ actor: String) -> Bool {
        actor == "user" || actor == "owner" || actor.hasPrefix("device:")
    }

    /// The rows to show. `history` stands in on older services that send no
    /// comments: each "commented" event becomes a comment without its text.
    /// A pending comment the board now holds (ours, same text) is dropped.
    static func rows(comments: [Hermes_Board_V1_ItemComment], history: [Hermes_Board_V1_ItemEvent],
                     pending: [PendingComment]) -> [CommentRow] {
        var rows: [CommentRow] = comments.map { comment in
            CommentRow(id: comment.id, author: comment.author,
                       body: comment.body.isEmpty ? nil : comment.body,
                       at: comment.hasAt ? comment.at.date : nil,
                       replyTo: comment.hasReplyTo ? comment.replyTo : nil,
                       status: .onBoard, pendingId: nil)
        }
        if comments.isEmpty {
            rows = history.filter { $0.kind == .commented }.map { event in
                CommentRow(id: event.hasTo ? event.to : "event-\(event.id)", author: event.actor, body: nil,
                           at: event.hasAt ? event.at.date : nil, replyTo: nil, status: .onBoard, pendingId: nil)
            }
        }
        let echoed = Set(rows.filter { isOwner($0.author) }.compactMap(\.body))
        for local in pending {
            // Confirmed and now on the board with its text: the board's row is enough.
            if local.state == .sent, echoed.contains(local.body) { continue }
            let status: CommentRow.Status = switch local.state {
            case .sending: .sending
            case .sent: .sent
            case .failed(let message): .failed(message)
            }
            rows.append(CommentRow(id: "local-\(local.id.uuidString)", author: "owner", body: local.body, at: local.at,
                                   replyTo: local.replyTo, status: status, pendingId: local.id))
        }
        return rows
    }

    /// Top-level comments with their replies. A reply whose parent isn't
    /// shown stays at the top level, so nothing is lost.
    static func grouped(_ rows: [CommentRow]) -> [CommentGroup] {
        let ids = Set(rows.map(\.id))
        let tops = rows.filter { $0.replyTo.map { !ids.contains($0) } ?? true }
        return tops.map { top in
            CommentGroup(comment: top, replies: rows.filter { $0.replyTo == top.id })
        }
    }

    /// Pending comments still worth keeping after a reload: sending, failed,
    /// and sent ones the board hasn't echoed with their text.
    static func stillPending(_ pending: [PendingComment], comments: [Hermes_Board_V1_ItemComment]) -> [PendingComment] {
        let echoed = Set(comments.filter { isOwner($0.author) && !$0.body.isEmpty }.map(\.body))
        return pending.filter { !($0.state == .sent && echoed.contains($0.body)) }
    }
}

extension AppStore {
    /// Posts a comment on a card (the owner's, `control` grant). Throws with the
    /// board's own reason when it refuses.
    func postComment(on id: String, _ body: String, replyTo: String?) async throws {
        var comment = Hermes_Board_V1_ItemAddComment()
        comment.id = id
        comment.body = body
        if let replyTo { comment.replyTo = replyTo }
        var request = Hermes_Board_V1_BoardRequest()
        request.request = .itemComment(comment)
        let envelope = try await client.request(.boardRequest(request), name: "item_comment")
        guard case .boardResponse(let response)? = envelope.body, case .edited(let result)? = response.response else { return }
        switch result.outcome {
        case .refused(let refused)?:
            let reasons = refused.unmet.map(\.text).filter { !$0.isEmpty }
            throw DaemonError(code: "refused", message: reasons.isEmpty ? "The board refused the comment." : reasons.joined(separator: " "))
        case .conflict?:
            throw DaemonError(code: "conflict", message: "The card changed while you wrote. Try again.")
        default:
            return
        }
    }
}
