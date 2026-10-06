import SwiftUI

/// A bot opens on what it reported (UX-024): its latest note to you, the
/// questions it asked, and what it is doing. Owner threads (H-128 D6) hold
/// the reports; an older daemon shows the bot's latest activity instead.
struct BotReportsPane: View {
    @Environment(AppStore.self) private var store
    @Environment(LensStore.self) private var lens
    let botId: String
    /// Opens the bot's chat, to answer it.
    let openChat: () -> Void
    @State private var entries: [ThreadEntry]?
    @State private var failure: String?

    private var bot: Bot? { store.bot(botId) }
    private var reports: [ThreadEntry] { (entries ?? []).filter { !$0.fromOwner }.reversed() }
    private var questions: [ThreadEntry] { reports.filter { $0.asks && $0.open } }

    var body: some View {
        List {
            if store.hasOwnerThreads {
                if let latest = reports.first {
                    Section {
                        Text(latest.text).font(.callout).textSelection(.enabled)
                    } header: {
                        SectionTitle(latest.at.map { "Latest report · \($0.relative)" } ?? "Latest report")
                    }
                }
                if !questions.isEmpty {
                    Section {
                        ForEach(questions) { question in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(question.text).font(.callout).lineLimit(4)
                                Button("Answer in Chat", action: openChat).font(.subheadline.weight(.semibold))
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        SectionTitle("Sent to you", count: questions.count)
                    }
                }
            }
            Section {
                if let doing = doingNow {
                    Text(doing).font(.callout)
                } else {
                    Text(bot.map { $0.state.label } ?? "—").foregroundStyle(Color.secondaryText)
                }
            } header: {
                SectionTitle("Doing now")
            }
            if store.hasOwnerThreads, reports.count > 1 {
                Section {
                    ForEach(reports.dropFirst().prefix(10)) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.text).font(.callout).lineLimit(5)
                            if let at = entry.at { Text(at.relative).font(.caption2).foregroundStyle(Color.secondaryText) }
                        }
                    }
                } header: {
                    SectionTitle("Earlier reports")
                }
            }
            if store.hasOwnerThreads, entries?.isEmpty == true || (entries != nil && reports.isEmpty) {
                EmptyNote(text: "\(bot?.name ?? "This bot") hasn't reported to you yet.", systemImage: "text.quote")
            }
            if !store.hasOwnerThreads {
                Text("Reports come from The Hermes 0.17 on \(store.computerName). Until then, this shows what the bot is doing.")
                    .font(.footnote).foregroundStyle(Color.secondaryText)
            }
            if let failure {
                Text(failure).font(.footnote).foregroundStyle(Color.errorText)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
        .task { await load() }
    }

    /// The bot's current step, else its latest word.
    private var doingNow: String? {
        if let turn = lens.latest[botId], turn.open, !turn.current.isEmpty { return turn.current }
        if let activity = store.activity[botId], !activity.text.isEmpty { return activity.text }
        if let outcome = lens.latest[botId]?.outcome, outcome.kind != "none", !outcome.text.isEmpty { return outcome.text }
        return nil
    }

    private func load() async {
        guard store.hasOwnerThreads else { return }
        do {
            entries = try await store.ownerThread(botId: botId)
            failure = nil
        } catch {
            failure = "Couldn’t load the reports. \(error.localizedDescription)"
        }
    }
}
