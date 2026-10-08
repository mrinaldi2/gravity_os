import Foundation

// H-248 (iOS half of H-247, UX-048): what blocks a release that only the owner
// can give. Every release payload carries `owner_blockers` (frozen shape):
// [{kind, id, title, item_id, bot, computer, created_at}], optional values null;
// a missing field means an older service.

/// One thing the release waits on.
struct OwnerBlocker: Identifiable, Equatable {
    enum Kind: String, Equatable {
        /// The owner's ruling on the package (awaiting_owner). id: the release's decision.
        case ruling
        /// An owner action (Run card). id: the action.
        case run
        case decision
        /// A bot's question to the owner. id: the comment.
        case question
        /// A permission request. id: the request.
        case permission

        /// UX-048: ruling → run/decision/permission → question.
        var group: Int {
            switch self {
            case .ruling: 0
            case .run, .decision, .permission: 1
            case .question: 2
            }
        }
    }

    let kind: Kind
    let id: String
    /// Raw text; the copy is written around it (version, reason, title, comment, tool).
    let title: String
    let itemId: String?
    /// A bot id; nil for a ruling.
    let botId: String?
    /// The run target, or the bot's computer for a permission.
    let computer: String?
    let createdAt: Date?

    init?(_ d: JSONDict) {
        guard let kind = Kind(rawValue: d.str("kind")), !d.str("id").isEmpty else { return nil }
        self.kind = kind
        id = d.str("id")
        title = d.str("title")
        itemId = d.optStr("item_id").flatMap { $0.isEmpty ? nil : $0 }
        botId = d.optStr("bot").flatMap { $0.isEmpty ? nil : $0 }
        computer = d.optStr("computer").flatMap { $0.isEmpty ? nil : $0 }
        createdAt = d.date("created_at")
    }

    /// The release's blockers in UX-048's order; nil on a service without the field.
    static func list(_ release: JSONDict) -> [OwnerBlocker]? {
        guard release["owner_blockers"] != nil else { return nil }
        return ordered(release.list("owner_blockers").compactMap(OwnerBlocker.init))
    }

    /// Ruling, then Run cards, decisions and permission requests, then questions;
    /// oldest first within each group.
    static func ordered(_ blockers: [OwnerBlocker]) -> [OwnerBlocker] {
        blockers.enumerated().sorted { a, b in
            if a.element.kind.group != b.element.kind.group { return a.element.kind.group < b.element.kind.group }
            let ta = a.element.createdAt ?? .distantPast, tb = b.element.createdAt ?? .distantPast
            return ta != tb ? ta < tb : a.offset < b.offset
        }.map(\.element)
    }
}

/// What a row's button does (UX-048 §Buttons).
enum BlockerAction: Equatable {
    /// Run without phone support: no button, the row says where to run it.
    case none
    /// Answer a decision: its screen.
    case openDecision(String)
    /// Answer a question: the card, with "Reply to <bot>" on that comment (H-210).
    case reply(itemId: String, commentId: String)
    /// Review a permission request: the bot, with the request on top.
    case reviewPermission(botId: String)
    /// Review… the ruling: the release review on this screen (UX-040).
    case reviewRuling

    static func of(_ blocker: OwnerBlocker) -> BlockerAction {
        switch blocker.kind {
        case .ruling: return .reviewRuling
        case .run: return .none
        case .decision: return .openDecision(blocker.id)
        case .question:
            guard let item = blocker.itemId else { return .none }
            return .reply(itemId: item, commentId: blocker.id)
        case .permission:
            guard let bot = blocker.botId else { return .none }
            return .reviewPermission(botId: bot)
        }
    }

    /// The button's text, also the row's accessibility action.
    var label: String? {
        switch self {
        case .none: nil
        case .openDecision, .reply: "Answer"
        case .reviewPermission: "Review"
        case .reviewRuling: "Review…"
        }
    }
}

/// UX-048's words.
enum WaitingWords {
    static let shown = 3

    /// "▲ Waiting for you · 2"
    static func header(_ count: Int) -> String { "▲ Waiting for you · \(count)" }

    static func more(_ hidden: Int) -> String { "+\(hidden) more" }

    /// The row's title. `bot` is the bot's name, when known.
    static func title(_ blocker: OwnerBlocker, bot: String?) -> String {
        switch blocker.kind {
        case .ruling: "◐ Test \(blocker.title) and rule on it"
        case .decision: "◆ Decide: \(blocker.title)"
        case .question: "? \(bot ?? "A bot") asks: \(blocker.title)"
        case .run: blocker.title
        case .permission: "\(bot ?? "A bot") wants to run \(blocker.title)"
        }
    }

    /// "who · where · time"; a Run card says where to run it instead.
    static func meta(_ blocker: OwnerBlocker, bot: String?, computer: String, now: Date = Date()) -> String {
        if blocker.kind == .run { return runOn(blocker.computer ?? computer) }
        let parts = [bot, blocker.computer ?? (computer.isEmpty ? nil : computer),
                     blocker.createdAt?.relative]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    static func runOn(_ computer: String) -> String {
        "Run it on \(computer.isEmpty ? "its computer" : computer), in The Hermes app."
    }

    /// Progress, on a service without owner_blockers.
    static let olderService = "Open Needs you to see what waits for you."
}

/// A `release_updated` push: that release's owner_blockers changed.
struct ReleaseUpdate: Equatable {
    let releaseId: String
    let id = UUID()
}
