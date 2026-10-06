import Foundation

/// The main chat (UX-024, H-128 D6): one thread per bot holding the owner's
/// messages and the bot's notes to the owner, on every computer.

/// One bot's thread as the list shows it, merged across computers.
struct ThreadCard: Identifiable, Equatable {
    /// The computer to read and write the thread on.
    let computerId: String
    let botId: String
    let botName: String
    let projectId: String
    let last: String
    let lastFromOwner: Bool
    let at: Date?
    let unread: Int
    let openQuestion: Bool
    /// The bot's own computer and id, which a stand-in on another computer shares.
    let origin: String

    var id: String { origin }

    init(_ thread: Hermes_Home_V1_OwnerThread, computerId: String) {
        self.computerId = computerId
        botId = thread.bot.botID
        botName = thread.bot.name
        projectId = thread.projectID
        last = thread.last.text
        lastFromOwner = thread.last.fromOwner
        at = thread.last.hasAt ? thread.last.at.date : nil
        unread = Int(thread.unread)
        openQuestion = thread.openQuestion
        origin = thread.bot.daemonID.isEmpty ? "\(computerId)/\(thread.bot.botID)" : "\(thread.bot.daemonID)/\(thread.bot.botID)"
    }
}

enum ThreadMerge {
    /// One card per bot. A linked bot's thread is listed by every computer
    /// that shows it; the one read on the bot's own computer wins (BotRef).
    /// Open questions first, then unread, then newest.
    static func merge(_ lists: [(computerId: String, daemonId: String?, threads: [Hermes_Home_V1_OwnerThread])]) -> [ThreadCard] {
        var byOrigin: [String: (card: ThreadCard, own: Bool)] = [:]
        for list in lists {
            for thread in list.threads {
                let card = ThreadCard(thread, computerId: list.computerId)
                let own = list.daemonId != nil && list.daemonId == thread.bot.daemonID
                if let kept = byOrigin[card.origin], kept.own || !own { continue }
                byOrigin[card.origin] = (card, own)
            }
        }
        return byOrigin.values.map(\.card).sorted { a, b in
            if a.openQuestion != b.openQuestion { return a.openQuestion }
            if (a.unread > 0) != (b.unread > 0) { return a.unread > 0 }
            if a.at != b.at { return (a.at ?? .distantPast) > (b.at ?? .distantPast) }
            return a.botName.localizedCaseInsensitiveCompare(b.botName) == .orderedAscending
        }
    }
}

extension AppStore {
    func ownerThreads() async throws -> [Hermes_Home_V1_OwnerThread] {
        let reply = try await client.request("owner_threads")
        return try HomeJSON.decode(Hermes_Home_V1_OwnerThreads.self, reply["owner_threads"]).threads
    }

    /// Marks the thread read up to `num`, so its unread count clears everywhere.
    func markThreadRead(botId: String, upTo num: Int64) async {
        _ = try? await client.request("owner_thread_read", ["bot_id": botId, "up_to_num": num])
        ownerThreadsVersion += 1
    }
}
