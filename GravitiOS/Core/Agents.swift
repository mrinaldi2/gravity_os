import Foundation

// What the daemon tells about a bot beyond its chat: its own browser, the
// commands it runs, and what bots say to each other. Gravity's
// docs/protocol.md and docs/bot-browser.md are the contract.

// MARK: Browser

struct BrowserTab: Identifiable, Equatable {
    let id: String
    let title: String
    let url: String

    /// A tab without a title yet goes by its address.
    var label: String { title.isEmpty ? url : title }
}

/// `browser_tabs`: the bot's tabs, and which one is on show.
struct BrowserTabs: Equatable {
    let botId: String
    /// False while the bot has no browser running.
    let open: Bool
    let tabs: [BrowserTab]
    let active: String?
    /// The view follows whichever tab the bot used last.
    let following: Bool
    /// Why the browser cannot be shown, e.g. its machine is offline.
    let reason: String?

    init(_ d: JSONDict) {
        botId = d.str("bot_id")
        open = d.bool("open")
        tabs = d.list("tabs").map { BrowserTab(id: $0.str("id"), title: $0.str("title"), url: $0.str("url")) }
        active = d.optStr("active")
        following = d["following"] as? Bool ?? true
        reason = d.optStr("reason")
    }

    var activeTab: BrowserTab? { tabs.first { $0.id == active } }
}

/// `browser_frame`: the newest screen of the tab on show, a JPEG.
struct BrowserFrame: Equatable {
    let botId: String
    let tabId: String
    let jpeg: Data
    let width: Int
    let height: Int

    init?(_ d: JSONDict) {
        guard let jpeg = (d["data"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return nil }
        botId = d.str("bot_id")
        tabId = d.str("tab_id")
        self.jpeg = jpeg
        width = d.int("width")
        height = d.int("height")
    }

    /// Only the tab on show is drawn: a frame from the tab just left is stale.
    func belongs(to tabs: BrowserTabs?) -> Bool {
        guard let tabs, tabs.open, tabs.botId == botId else { return false }
        return tabs.active == tabId
    }
}

/// One thing the bot did in a browser (`list_browser_activity`).
struct BrowserAction: Identifiable, Equatable {
    let turnId: String
    let stepId: String
    let at: Date?
    /// In the owner's own Chrome rather than the bot's browser.
    let ownersChrome: Bool
    let title: String
    let subtitle: String?
    let status: String
    let trigger: ChatTrigger?

    var id: String { stepId }

    init(_ d: JSONDict) {
        turnId = d.str("turn_id")
        stepId = d.str("step_id")
        at = d.date("at")
        ownersChrome = d.str("browser") == "owners_chrome"
        title = d.str("title")
        subtitle = d.optStr("subtitle")
        status = d.str("status")
        trigger = d.dict("trigger").flatMap { row in
            (try? JSONSerialization.data(withJSONObject: row))
                .flatMap { try? ChatDecoding.decoder.decode(ChatTrigger.self, from: $0) }
        }
    }
}

/// Consecutive actions of one turn, under what started it.
struct BrowserTurnGroup: Identifiable, Equatable {
    let turnId: String
    let at: Date?
    /// "Task from lead", "You", …
    let why: String
    /// What was asked.
    let ask: String
    let actions: [BrowserAction]

    var id: String { "\(turnId)#\(actions.first?.stepId ?? "")" }

    /// Groups newest-first actions by turn, keeping that order.
    static func group(_ actions: [BrowserAction]) -> [BrowserTurnGroup] {
        var groups: [BrowserTurnGroup] = []
        for action in actions {
            if let last = groups.last, last.turnId == action.turnId {
                groups[groups.count - 1] = BrowserTurnGroup(
                    turnId: last.turnId, at: last.at, why: last.why, ask: last.ask, actions: last.actions + [action])
                continue
            }
            groups.append(BrowserTurnGroup(
                turnId: action.turnId, at: action.at,
                why: action.trigger?.headline ?? "Turn", ask: action.trigger?.text ?? "", actions: [action]))
        }
        return groups
    }
}

// MARK: Commands

/// A command the bot ran or is running (`list_bot_commands`).
struct BotCommand: Identifiable, Equatable {
    let id: String
    let command: String
    let description: String?
    let background: Bool
    /// running, done, failed or stopped.
    let status: String
    let startedAt: Date?
    let endedAt: Date?
    let exitCode: Int?
    let taskId: String?
    /// For a running background command, the live end of its output.
    let output: String?

    init(_ d: JSONDict) {
        id = d.str("id")
        command = d.str("command")
        description = d.optStr("description")
        background = d.bool("background")
        status = d.str("status")
        startedAt = d.date("started_at")
        endedAt = d.date("ended_at")
        exitCode = d.optInt("exit_code")
        taskId = d.optStr("task_id")
        output = d["output"] as? String
    }

    var isRunning: Bool { status == "running" }

    /// What it is for, or its first line.
    var title: String { description ?? command.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? "" }

    /// A finished command's outcome: its status, or the exit code when that says more.
    var outcome: String? {
        guard !isRunning else { return nil }
        if let exitCode, exitCode != 0 { return "exit \(exitCode)" }
        return status
    }

    /// The start time and, once ended, how long it took.
    func when(_ format: (Date) -> String) -> String {
        guard let startedAt else { return "" }
        guard let endedAt else { return format(startedAt) }
        return "\(format(startedAt)) · \(Self.elapsed(from: startedAt, to: endedAt))"
    }

    /// "12s", "4m 03s", "1h 05m".
    static func elapsed(from: Date, to: Date) -> String {
        let seconds = max(0, Int((to.timeIntervalSince(from)).rounded()))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m \(String(format: "%02d", seconds % 60))s" }
        return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }

    /// Running first, then what finished, each in the daemon's order.
    static func sections(_ commands: [BotCommand]) -> (running: [BotCommand], finished: [BotCommand]) {
        (commands.filter(\.isRunning), commands.filter { !$0.isRunning })
    }

    /// The output worth a Copy control: none when there is nothing to copy.
    var copyableOutput: String? {
        guard let output, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return output
    }

    /// A background command still writing output is worth polling.
    static func needsPolling(_ commands: [BotCommand]) -> Bool {
        commands.contains { $0.isRunning && $0.background }
    }
}

// MARK: Conversations between bots

struct AgentBot: Identifiable, Equatable {
    let id: String
    let name: String
    let avatar: String
    /// The peer it runs on, for a linked bot.
    let machine: String?
    let deleted: Bool

    init(id: String, name: String, avatar: String, machine: String?, deleted: Bool) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.machine = machine
        self.deleted = deleted
    }

    init(_ d: JSONDict) {
        self.init(id: d.str("id"), name: d.str("name"), avatar: d.str("avatar"),
                  machine: d.optStr("machine"), deleted: d.bool("deleted"))
    }

    /// "windev @ win-pc" for a linked bot.
    var label: String { machine.map { "\(name) @ \($0)" } ?? name }
}

/// A message between two bots (`list_agent_conversation`).
struct AgentMessage: Identifiable, Equatable {
    let id: String
    let num: Int
    let fromBotId: String
    let toBotId: String
    /// task, reply, done, note or chat.
    let kind: String
    let body: String
    let refMessageId: String?
    let taskState: String?
    let createdAt: Date?

    init(_ d: JSONDict) {
        id = d.str("id")
        num = d.int("num")
        fromBotId = d.str("from_bot_id")
        toBotId = d.str("to_bot_id")
        kind = d.str("kind")
        body = d.str("body")
        refMessageId = d.optStr("ref_message_id")
        taskState = d.dict("task")?.optStr("state")
        createdAt = d.date("created_at")
    }

    var kindLabel: String {
        switch kind {
        case "done": "result"
        case "chat": "message"
        default: kind
        }
    }
}

/// A pair of bots that talked, with the newest word (`list_agent_conversations`).
struct AgentConversation: Identifiable, Equatable {
    let botIds: [String]
    let messageCount: Int
    let lastAt: Date?
    let last: AgentMessage?

    init(_ d: JSONDict) {
        botIds = d.strings("bot_ids")
        messageCount = d.int("message_count")
        lastAt = d.date("last_at")
        last = d.dict("last").map(AgentMessage.init)
    }

    var id: String { AgentConversations.key(botIds) }
}

/// Naming pairs, merging pages, and which side each bot sits on.
enum AgentConversations {
    /// A stable key for a pair, whatever order its ids come in.
    static func key(_ ids: [String]) -> String { ids.sorted().joined(separator: "|") }

    /// A fetched page merged into what is loaded: one copy of each, oldest first.
    static func merge(_ loaded: [AgentMessage], _ page: [AgentMessage]) -> [AgentMessage] {
        var byId: [String: AgentMessage] = [:]
        for message in loaded + page { byId[message.id] = message }
        return byId.values.sorted { $0.num < $1.num }
    }

    /// The pair as (left, right): the bot higher in the project's list sits
    /// on the left, so a lead keeps its side however far back the thread is
    /// read. Bots no longer listed (archived) go after those that are.
    static func sides(_ ids: [String], order: [String]) -> (left: String, right: String) {
        let a = ids.first ?? "", b = ids.count > 1 ? ids[1] : ""
        func rank(_ id: String) -> Int { order.firstIndex(of: id) ?? .max }
        return rank(b) < rank(a) ? (b, a) : (a, b)
    }

    static func bot(_ id: String, in bots: [String: AgentBot]) -> AgentBot {
        bots[id] ?? AgentBot(id: id, name: "unknown bot", avatar: "", machine: nil, deleted: true)
    }

    /// "lead ↔ windev @ win-pc".
    static func title(_ pair: (left: String, right: String), bots: [String: AgentBot]) -> String {
        "\(bot(pair.left, in: bots).label) ↔ \(bot(pair.right, in: bots).label)"
    }

    /// The list's preview: who said the last thing, and what.
    static func preview(_ conversation: AgentConversation, bots: [String: AgentBot]) -> String {
        guard let last = conversation.last else { return "" }
        let body = last.body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return "\(bot(last.fromBotId, in: bots).name): \(body)"
    }
}
