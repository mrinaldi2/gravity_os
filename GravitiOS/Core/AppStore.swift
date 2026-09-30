import Foundation
import Observation
import UIKit

/// Receives a bot's terminal stream while its terminal screen is open.
@MainActor
protocol TerminalSink: AnyObject {
    func attached(seq: Int, resumed: Bool)
    func output(seq: Int, data: String)
    /// The connection came back: re-attach from the last seen cursor.
    func reattach()
}

struct Notice: Identifiable, Equatable {
    let id = UUID()
    let level: String
    let title: String
    let body: String
    let decisionId: String?
}

/// Everything the UI shows, kept current from replies and pushes.
@MainActor
@Observable
final class AppStore {
    var status: ConnectionStatus = .idle
    var endpoint: Endpoint?
    var grants: Set<String> = []
    var serverVersion = ""
    var deviceId: String?

    var projects: [Project] = []
    var bots: [Bot] = []
    var activity: [String: BotActivity] = [:]
    /// bot id → its DM thread.
    var conversations: [String: Conversation] = [:]
    /// conversation id → messages, oldest first.
    var messages: [String: [BusMessage]] = [:]
    var decisions: [Decision] = []
    var pendingCounts = PendingCounts()
    /// bot id → what its native permission prompt is asking.
    var approvals: [String: String] = [:]
    /// bot id → when the owner last looked at it.
    var lastSeen: [String: Date] = [:]
    var notice: Notice?
    var inBackground = false

    @ObservationIgnored let client = DaemonClient()
    @ObservationIgnored private var sinks: [String: TerminalSink] = [:]

    var canControl: Bool { grants.contains("control") }
    var canApprove: Bool { grants.contains("approve") }
    var hasEndpoint: Bool { endpoint != nil }

    init() {
        client.onStatus = { [weak self] status in self?.statusChanged(status) }
        client.onHello = { [weak self] hello in self?.helloReceived(hello) }
        client.onPush = { [weak self] type, frame in self?.pushReceived(type, frame) }
        if let seen = UserDefaults.standard.dictionary(forKey: "lastSeen") as? [String: Double] {
            lastSeen = seen.mapValues(Date.init(timeIntervalSince1970:))
        }
        restoreEndpoint()
    }

    // MARK: Endpoint

    private func restoreEndpoint() {
        let defaults = UserDefaults.standard
        #if DEBUG
        // Simulator runs against a test daemon: -gravHost … -gravPort … -gravToken …
        if let host = defaults.string(forKey: "gravHost"), let token = defaults.string(forKey: "gravToken") {
            let port = defaults.integer(forKey: "gravPort")
            connect(Endpoint(host: host, port: port == 0 ? 49777 : port, token: token), remember: false)
            return
        }
        #endif
        guard let host = defaults.string(forKey: "host"), let token = Keychain.loadToken() else { return }
        let port = defaults.integer(forKey: "port")
        connect(Endpoint(host: host, port: port == 0 ? 49777 : port, token: token), remember: false)
    }

    func connect(_ endpoint: Endpoint, remember: Bool = true) {
        if remember {
            UserDefaults.standard.set(endpoint.host, forKey: "host")
            UserDefaults.standard.set(endpoint.port, forKey: "port")
            Keychain.saveToken(endpoint.token)
        }
        self.endpoint = endpoint
        client.start(endpoint)
    }

    /// Drop the saved connection and its token.
    func forget() {
        client.stop()
        Keychain.deleteToken()
        UserDefaults.standard.removeObject(forKey: "host")
        UserDefaults.standard.removeObject(forKey: "port")
        endpoint = nil
        clear()
    }

    private func clear() {
        grants = []
        projects = []
        bots = []
        activity = [:]
        conversations = [:]
        messages = [:]
        decisions = []
        pendingCounts = PendingCounts()
        approvals = [:]
    }

    // MARK: Connection events

    private func statusChanged(_ status: ConnectionStatus) {
        self.status = status
        guard status == .connected else { return }
        Task { await refresh() }
        for sink in sinks.values { sink.reattach() }
    }

    private func helloReceived(_ hello: JSONDict) {
        grants = Set(hello.strings("grants"))
        serverVersion = hello.str("server_version")
        deviceId = hello.optStr("device_id")
    }

    func refresh() async {
        async let projectsReply = try? client.request("list_projects")
        async let botsReply = try? client.request("list_bots")
        async let activityReply = try? client.request("list_bot_activity")
        async let conversationsReply = try? client.request("list_conversations")
        if let reply = await projectsReply {
            projects = reply.list("projects").map(Project.init).filter { $0.deletedAt == nil }
        }
        if let reply = await botsReply {
            bots = reply.list("bots").map(Bot.init).filter { $0.deletedAt == nil }
        }
        if let reply = await activityReply {
            activity = Dictionary(
                reply.list("activity").map { ($0.str("bot_id"), BotActivity($0)) },
                uniquingKeysWith: { _, newest in newest })
        }
        if let reply = await conversationsReply {
            conversations = Dictionary(
                reply.list("conversations").map { ($0.str("bot_id"), Conversation($0)) },
                uniquingKeysWith: { _, newest in newest })
        }
        await refreshDecisions()
    }

    func refreshDecisions() async {
        // The daemon's default list is only what still wants an answer, so
        // held and recently settled ones are asked for by name.
        async let pendingReply = try? client.request("list_decisions", ["limit": 200])
        async let heldReply = try? client.request("list_decisions", ["state": "held", "limit": 100])
        async let settledReply = try? client.request("list_decisions", ["state": "settled", "limit": 40])
        let replies = await [pendingReply, heldReply, settledReply]
        if replies.contains(where: { $0 != nil }) {
            let known = Dictionary(decisions.map { ($0.id, $0.comments) }, uniquingKeysWith: { first, _ in first })
            decisions = replies.compactMap { $0 }.flatMap { $0.list("decisions") }.map { row in
                var decision = Decision(row)
                if decision.comments.isEmpty { decision.comments = known[decision.id] ?? [] }
                return decision
            }
        }
        await refreshCounts()
    }

    private func refreshCounts() async {
        guard let reply = try? await client.request("count_pending_decisions"),
              let counts = reply.dict("counts") else { return }
        pendingCounts = PendingCounts(counts)
        Notifier.setBadge(pendingCounts.total)
    }

    // MARK: Pushes

    private func pushReceived(_ type: String, _ frame: JSONDict) {
        switch type {
        case "term":
            sinks[frame.str("bot_id")]?.output(seq: frame.int("seq"), data: frame.str("data"))
        case "attached":
            sinks[frame.str("bot_id")]?.attached(seq: frame.int("seq"), resumed: frame.bool("resumed"))
        case "bot_state":
            botStateChanged(frame)
        case "bot_updated":
            if let bot = frame.dict("bot").map(Bot.init) { upsert(bot) }
        case "project_updated":
            if let project = frame.dict("project").map(Project.init) { upsert(project) }
        case "activity_update":
            if let entry = frame.dict("activity").map(BotActivity.init) { activity[entry.botId] = entry }
        case "message_new":
            if let message = frame.dict("message").map(BusMessage.init) { append(message) }
        case "approval_pending":
            approvalPending(frame)
        case "notify":
            notified(frame)
        case "decision_update":
            if let decision = frame.dict("decision").map(Decision.init) { upsert(decision) }
        case "decision_deleted":
            decisions.removeAll { $0.id == frame.str("decision_id") }
            Task { await refreshCounts() }
        case "decision_comment_new":
            if let comment = frame.dict("comment").map(DecisionComment.init) { append(comment) }
        default:
            break
        }
    }

    private func botStateChanged(_ frame: JSONDict) {
        let id = frame.str("bot_id")
        guard let index = bots.firstIndex(where: { $0.id == id }) else { return }
        let state = BotState(rawValue: frame.str("state")) ?? .unknown
        let previous = bots[index].state
        bots[index].state = state
        bots[index].stateReason = frame.str("reason")
        if state != .waitingForApproval { approvals[id] = nil }
        if inBackground, state == .waitingForUser, previous != state {
            Notifier.post(title: "\(bots[index].name) is waiting for you", body: activity[id]?.text ?? "", id: "wait-\(id)")
        }
    }

    private func approvalPending(_ frame: JSONDict) {
        let id = frame.str("bot_id")
        let detail = frame.str("detail")
        approvals[id] = detail
        if inBackground {
            Notifier.post(title: "\(bot(id)?.name ?? "A bot") needs approval", body: detail, id: "approval-\(id)")
        }
    }

    private func notified(_ frame: JSONDict) {
        let entry = Notice(level: frame.str("level"), title: frame.str("title"),
                           body: frame.str("body"), decisionId: frame.optStr("decision_id"))
        if inBackground {
            Notifier.post(title: entry.title, body: entry.body)
        } else {
            notice = entry
        }
    }

    private func upsert(_ bot: Bot) {
        bots.removeAll { $0.id == bot.id }
        if bot.deletedAt == nil {
            bots.append(bot)
            // A bot created after connect has a DM thread we have not listed yet.
            if conversations[bot.id] == nil { Task { await refreshConversations() } }
        }
    }

    private func refreshConversations() async {
        guard let reply = try? await client.request("list_conversations") else { return }
        conversations = Dictionary(
            reply.list("conversations").map { ($0.str("bot_id"), Conversation($0)) },
            uniquingKeysWith: { _, newest in newest })
    }

    private func upsert(_ project: Project) {
        projects.removeAll { $0.id == project.id }
        if project.deletedAt == nil { projects.append(project) }
    }

    private func upsert(_ decision: Decision) {
        var updated = decision
        if let index = decisions.firstIndex(where: { $0.id == decision.id }) {
            // Pushes carry the list view; keep a thread we already loaded.
            if updated.comments.isEmpty { updated.comments = decisions[index].comments }
            decisions[index] = updated
        } else {
            decisions.insert(updated, at: 0)
            if inBackground, decision.state == "open" {
                Notifier.post(title: "\(decision.raisedByName) needs a decision", body: decision.title, id: "decision-\(decision.id)")
            }
        }
        Task { await refreshCounts() }
    }

    private func append(_ comment: DecisionComment) {
        guard let index = decisions.firstIndex(where: { $0.id == comment.decisionId }),
              !decisions[index].comments.contains(where: { $0.id == comment.id }) else { return }
        decisions[index].comments.append(comment)
    }

    private func append(_ message: BusMessage) {
        guard var thread = messages[message.conversationId],
              !thread.contains(where: { $0.id == message.id }) else { return }
        thread.append(message)
        messages[message.conversationId] = thread
    }

    // MARK: Lookups

    func bot(_ id: String) -> Bot? { bots.first { $0.id == id } }

    func bots(in project: Project) -> [Bot] {
        bots.filter { $0.projectId == project.id }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var sortedProjects: [Project] {
        projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func projectName(_ id: String) -> String { projects.first { $0.id == id }?.name ?? "" }

    func isUnread(_ bot: Bot) -> Bool {
        guard let at = activity[bot.id]?.at else { return false }
        return at > (lastSeen[bot.id] ?? .distantPast)
    }

    func markSeen(_ botId: String) {
        lastSeen[botId] = Date()
        UserDefaults.standard.set(lastSeen.mapValues(\.timeIntervalSince1970), forKey: "lastSeen")
    }

    // MARK: Terminal

    func register(_ sink: TerminalSink, for botId: String) { sinks[botId] = sink }

    func unregister(_ sink: TerminalSink, for botId: String) {
        guard sinks[botId] === sink else { return }
        sinks[botId] = nil
        client.send("detach", ["bot_id": botId])
    }

    /// Type text into a bot's terminal, then press return.
    func submitToTerminal(_ botId: String, text: String) async {
        // Several lines go in as one bracketed paste so the newlines do not submit early.
        let data = text.contains("\n") ? "\u{1b}[200~\(text)\u{1b}[201~" : text
        client.send("input", ["bot_id": botId, "data": data])
        // Sent together, the return is read as part of the text.
        try? await Task.sleep(for: .milliseconds(200))
        client.send("input", ["bot_id": botId, "data": "\r"])
    }

    // MARK: Messages

    func loadMessages(botId: String) async {
        if conversations[botId] == nil { await refreshConversations() }
        guard let conversation = conversations[botId],
              let reply = try? await client.request("list_messages", ["conversation_id": conversation.id, "limit": 100])
        else { return }
        messages[conversation.id] = reply.list("messages").map(BusMessage.init)
            .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    func sendMessage(botId: String, body: String) async throws {
        let reply = try await client.request("send_user_message", ["to_bot_id": botId, "body": body])
        if let message = reply.dict("message").map(BusMessage.init) { append(message) }
    }

    // MARK: Projects and bots

    func createProject(name: String) async throws -> Project {
        let reply = try await client.request("create_project", ["name": name])
        guard let row = reply.dict("project") else {
            throw DaemonError(code: "internal", message: "The daemon did not return the project.")
        }
        let project = Project(row)
        upsert(project)
        return project
    }

    /// Only the project is required: without a name the daemon picks "New Bot",
    /// and without a charter the bot starts by asking what it is for.
    func createBot(projectId: String, name: String, description: String, instructions: String,
                   avatar: String?) async throws -> Bot {
        var fields: JSONDict = ["project_id": projectId]
        if !name.isEmpty { fields["name"] = name }
        if !description.isEmpty { fields["description"] = description }
        if !instructions.isEmpty { fields["instructions"] = instructions }
        if let avatar { fields["avatar"] = avatar }
        let reply = try await client.request("create_bot", fields)
        guard let row = reply.dict("bot") else {
            throw DaemonError(code: "internal", message: "The daemon did not return the bot.")
        }
        let bot = Bot(row)
        upsert(bot)
        return bot
    }

    // MARK: Decisions

    func loadDecision(_ id: String) async {
        guard let reply = try? await client.request("get_decision", ["decision_id": id]),
              let decision = reply.dict("decision").map(Decision.init) else { return }
        if let index = decisions.firstIndex(where: { $0.id == id }) {
            decisions[index] = decision
        } else {
            decisions.insert(decision, at: 0)
        }
    }

    /// Runs a request whose reply is the changed decision.
    func decide(_ type: String, _ fields: JSONDict) async throws {
        let reply = try await client.request(type, fields)
        if let decision = reply.dict("decision").map(Decision.init) { upsert(decision) }
    }

    /// Answer and settle in one step; the asking bots are told.
    func answerAndPublish(_ id: String, option: String?, text: String, reason: String?) async throws {
        var fields: JSONDict = ["decision_id": id, "ruling_text": text]
        if let option { fields["ruling_option"] = option }
        if let reason, !reason.isEmpty { fields["ruling_reason"] = reason }
        try await decide("answer_decision", fields)
        try await publish(id)
    }

    func publish(_ id: String) async throws {
        _ = try await client.request("publish_decisions", ["items": [["decision_id": id]]])
        await loadDecision(id)
        await refreshCounts()
    }

    func comment(_ id: String, body: String) async throws {
        let reply = try await client.request("comment_decision", ["decision_id": id, "body": body])
        if let comment = reply.dict("comment").map(DecisionComment.init) { append(comment) }
    }
}
