import Foundation

// A bot's chat as the daemon serves it (`list_chat`, `chat_turns`): the same
// turns Gravity Lens used to make from the transcripts, now parsed by gravityd.
// See docs/superpowers/specs/2026-09-16-chat-pane-design.md in Gravity.

struct ChatTurn: Decodable, Identifiable, Equatable {
    let id: String
    let botId: String
    let startedAt: String
    let endedAt: String?
    let durationMs: Int?
    let open: Bool
    let trigger: ChatTrigger
    let items: [ChatItem]
    let stats: ChatStats
}

/// What woke the bot. `kind`: owner, bus, routine, ruling, resumed, background.
struct ChatTrigger: Decodable, Equatable {
    let kind: String
    let text: String?
    /// Owner: `chat` (the app's composer) or `terminal`.
    let via: String?
    let from: String?
    let msgKind: String?
    let num: Int?
    let taskId: String?
    /// Routine: its name.
    let name: String?
    let runId: String?
    let decisionId: String?
}

/// One thing in a turn. `type`: text, step, sent, completed, decision, aside.
struct ChatItem: Decodable, Equatable, Identifiable {
    let type: String
    let id: String
    let markdown: String?
    // step
    let tool: String?
    let title: String?
    let subtitle: String?
    /// running, ok or error.
    let status: String?
    let minor: Bool?
    let added: Int?
    let removed: Int?
    let images: [ChatImageRef]?
    // sent
    let to: String?
    let msgKind: String?
    let body: String?
    // completed
    let taskId: String?
    let result: String?
    let artifacts: [ChatFileRef]?
    // decision
    let decisionId: String?
    // aside: compacted, interrupted, incoming
    let kind: String?
    let text: String?
}

struct ChatImageRef: Decodable, Equatable {
    let id: String
    let mime: String
}

struct ChatFileRef: Decodable, Equatable {
    let path: String
    let name: String
}

struct ChatStats: Decodable, Equatable {
    let commands: Int
    let reads: Int
    let edits: Int
    let added: Int
    let removed: Int
    let sent: Int
    let images: Int
    let errors: Int
}

/// A file the daemon sends back (`read_file`, `get_chat_image`).
struct DaemonFile {
    let name: String
    let mime: String
    let text: String?
    let data: Data?

    init(_ d: JSONDict) {
        name = d.str("name")
        mime = d.str("mime")
        text = d["text"] as? String
        data = (d["base64"] as? String).flatMap { Data(base64Encoded: $0) }
    }
}

/// A task a bot was given or handed out (`list_tasks`, `get_task`).
struct BotTask: Identifiable, Equatable {
    let id: String
    /// open, done, cancelled or expired.
    let state: String
    /// `assigned`: this bot was asked; `delegated`: it asked someone else.
    let role: String
    let otherName: String
    /// Set when the other bot runs on a peer machine.
    let otherMachine: String?
    let request: String
    let requestTruncated: Bool
    let result: String?
    let resultTruncated: Bool
    let createdAt: Date?
    let deadlineAt: Date?
    let closedAt: Date?

    init(_ d: JSONDict) {
        id = d.str("id")
        state = d.str("state")
        role = d.str("role")
        let other = d.dict("other") ?? [:]
        otherName = other.str("name")
        otherMachine = other.optStr("machine")
        request = d.str("request")
        requestTruncated = d.bool("request_truncated")
        result = d["result"] as? String
        resultTruncated = d.bool("result_truncated")
        createdAt = d.date("created_at")
        deadlineAt = d.date("deadline_at")
        closedAt = d.date("closed_at")
    }

    var isOpen: Bool { state == "open" }

    /// "From lead" or "To windev @ PC".
    var counterpart: String {
        let machine = otherMachine.map { " @ \($0)" } ?? ""
        return role == "assigned" ? "From \(otherName)\(machine)" : "To \(otherName)\(machine)"
    }

    /// Cut in the list: `get_task` has the whole text.
    var cut: Bool { requestTruncated || resultTruncated }
}

enum ChatDecoding {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    static func turns(_ rows: [JSONDict]) -> [ChatTurn] {
        rows.compactMap { row in
            guard let data = try? JSONSerialization.data(withJSONObject: row) else { return nil }
            return try? decoder.decode(ChatTurn.self, from: data)
        }
    }
}

// MARK: Into the phone's turn model

/// The phone's views were built on Gravity Lens's turns and events; a daemon
/// turn is reshaped into those, so every view reads both.
extension ChatTurn {
    var lastActivity: String { open ? WireDate.string(Date()) : (endedAt ?? startedAt) }

    func lensTurn(botName: String?) -> LensTurn? {
        let steps = items.filter { $0.type == "step" }
        let current = open ? (steps.last { $0.minor != true }?.title ?? steps.last?.title ?? "") : ""
        let cover = steps.lazy.compactMap { $0.images?.first }.first
        var row: JSONDict = [
            "id": id, "started_at": startedAt, "updated_at": lastActivity, "open": open,
            "trigger": triggerRow, "outcome": outcomeRow, "current": current, "bot_id": botId,
            "stats": [
                "images": stats.images, "commands": stats.commands, "reads": stats.reads,
                "edits": stats.edits, "added": stats.added, "removed": stats.removed, "sent": stats.sent,
                "incoming": items.filter { $0.type == "aside" && $0.kind == "incoming" }.count,
                "errors": stats.errors, "steps": steps.count, "files": [String](),
            ] as JSONDict,
        ]
        if let endedAt { row["ended_at"] = endedAt }
        if let durationMs { row["duration_ms"] = durationMs }
        if let botName { row["bot_name"] = botName }
        if let cover { row["cover"] = Self.imageRow(cover) }
        return Self.decode(LensTurn.self, row)
    }

    var lensEvents: [LensEvent] {
        items.compactMap { item in Self.decode(LensEvent.self, eventRow(item)) }
    }

    private var triggerRow: JSONDict {
        let text = trigger.text ?? ""
        switch trigger.kind {
        case "owner":
            if trigger.via == "terminal" { return ["kind": "typed", "from": "You", "msg_kind": "", "text": text] }
            return ["kind": "owner", "from": "You", "msg_kind": "chat", "text": text]
        case "bus":
            return ["kind": "message", "from": trigger.from ?? "", "msg_kind": trigger.msgKind ?? "", "text": text]
        case "routine":
            return ["kind": "routine", "from": trigger.name ?? "", "msg_kind": "", "text": text]
        case "ruling":
            return ["kind": "message", "from": "You", "msg_kind": "decision", "text": text]
        case "resumed":
            return ["kind": "continued", "from": "", "msg_kind": "", "text": ""]
        default:
            return ["kind": "background", "from": "", "msg_kind": "", "text": text]
        }
    }

    /// How the turn ended: its last words, a message it sent, or a finished task.
    private var outcomeRow: JSONDict {
        for item in items.reversed() {
            switch item.type {
            case "text": return ["kind": "text", "text": item.markdown ?? "", "to": ""]
            case "sent": return ["kind": "message", "text": item.body ?? "", "to": item.to ?? ""]
            case "completed": return ["kind": "completed", "text": item.result ?? "", "to": ""]
            default: continue
            }
        }
        return ["kind": "none", "text": "", "to": ""]
    }

    private func eventRow(_ item: ChatItem) -> JSONDict {
        var row: JSONDict = ["id": item.id, "at": startedAt, "title": item.title ?? ""]
        switch item.type {
        case "text":
            row["kind"] = "text"
            row["text"] = item.markdown ?? ""
        case "step":
            row["kind"] = "tool"
            row["tool"] = item.tool ?? ""
            if let subtitle = item.subtitle {
                row["subtitle"] = subtitle
                row["path"] = subtitle
            }
            row["error"] = item.status == "error"
            row["running"] = item.status == "running"
            row["minor"] = item.minor ?? false
            row["has_detail"] = true
            if let added = item.added { row["added"] = added }
            if let removed = item.removed { row["removed"] = removed }
            if let images = item.images, !images.isEmpty { row["images"] = images.map(Self.imageRow) }
        case "sent":
            row["kind"] = "sent"
            row["to"] = item.to ?? ""
            row["msg_kind"] = item.msgKind ?? ""
            row["text"] = item.body ?? ""
        case "completed":
            row["kind"] = "completed"
            row["text"] = item.result ?? ""
            if let taskId = item.taskId { row["task_id"] = taskId }
            row["artifacts"] = (item.artifacts ?? []).map(\.path)
        case "decision":
            row["kind"] = "decision"
            if let decisionId = item.decisionId { row["decision_id"] = decisionId }
        default:
            row["kind"] = item.kind == "compacted" ? "compacted" : (item.kind ?? "aside")
            row["text"] = item.text ?? ""
        }
        return row
    }

    private static func imageRow(_ ref: ChatImageRef) -> JSONDict {
        ["id": ref.id, "kind": "chat", "name": ref.mime.replacingOccurrences(of: "image/", with: "image."),
         "path": "", "exists": true]
    }

    private static let lensDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private static func decode<T: Decodable>(_ type: T.Type, _ row: JSONDict) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: row) else { return nil }
        return try? lensDecoder.decode(type, from: data)
    }
}
