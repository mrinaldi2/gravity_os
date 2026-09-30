import SwiftUI

/// Where a turn came from, in words.
extension LensTrigger {
    var headline: String {
        switch kind {
        case "message":
            let sender = from.isEmpty ? "someone" : from
            switch msgKind {
            case "task": return "Task from \(sender)"
            case "reply": return "Reply from \(sender)"
            case "done": return "\(sender) finished a task"
            case "decision": return "Your ruling"
            case "note": return from == "You" ? "Note from Gravity" : "Note from \(sender)"
            default: return "Message from \(sender)"
            }
        case "typed": return "You, in the terminal"
        case "background": return "Background job finished"
        default: return "Continued"
        }
    }

    var symbol: String {
        switch kind {
        case "typed": "person.fill"
        case "background": "clock.arrow.circlepath"
        case "message": msgKind == "task" ? "tray.and.arrow.down.fill" : "bubble.left.fill"
        default: "arrow.turn.down.right"
        }
    }
}

extension LensStats {
    /// "12 commands · 3 files +120 −4 · 2 messages"
    var line: String {
        var parts: [String] = []
        if commands > 0 { parts.append("\(commands) command\(commands == 1 ? "" : "s")") }
        if edits > 0 { parts.append("\(edits) file\(edits == 1 ? "" : "s") +\(added) −\(removed)") }
        if sent > 0 { parts.append("\(sent) message\(sent == 1 ? "" : "s") sent") }
        if parts.isEmpty, reads > 0 { parts.append("read \(reads) file\(reads == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

/// One turn at a glance: who asked, what came of it, how much work it took.
struct TurnCard: View {
    @Environment(AppStore.self) private var store
    let turn: LensTurn
    var showBot = false
    /// For a bot's own list, where turns do not carry the bot id.
    var botIdFallback = ""

    private var botId: String { turn.botId ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if showBot, let bot = store.bot(botId) {
                    AvatarView(avatar: bot.avatar, name: bot.name, size: 26)
                    Text(bot.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                } else if showBot {
                    Text(turn.botName ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                } else {
                    trigger
                }
                Spacer(minLength: 4)
                if turn.open {
                    ProgressView().controlSize(.mini)
                } else if let at = turn.updated {
                    Text(at.relative).font(.caption).foregroundStyle(.tertiary)
                }
            }
            if showBot { trigger }
            if !turn.trigger.text.isEmpty {
                Text(plain(turn.trigger.text))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if turn.open, !turn.current.isEmpty {
                Label(turn.current, systemImage: "play.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.tint)
                    .lineLimit(1)
            }
            outcome
            if let cover = turn.cover, let bot = turn.botId ?? Optional(botIdFallback) {
                LensImageView(source: .bot(bot, cover))
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        if turn.stats.images > 1 {
                            Label("\(turn.stats.images)", systemImage: "photo.on.rectangle")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(6)
                        }
                    }
            }
            if !turn.stats.line.isEmpty || turn.stats.errors > 0 {
                HStack(spacing: 8) {
                    Text(turn.stats.line)
                    if turn.stats.errors > 0 {
                        Label("\(turn.stats.errors)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var trigger: some View {
        Label(turn.trigger.headline, systemImage: turn.trigger.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    @ViewBuilder private var outcome: some View {
        switch turn.outcome.kind {
        case "none":
            EmptyView()
        default:
            VStack(alignment: .leading, spacing: 3) {
                if turn.outcome.kind == "message" {
                    Label("To \(turn.outcome.to)", systemImage: "arrowshape.turn.up.right.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.tint)
                } else if turn.outcome.kind == "completed" {
                    Label("Task completed", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.green)
                }
                Text(plain(turn.outcome.text)).font(.callout).lineLimit(4)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    /// Markdown markers stripped, for a few lines of preview.
    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\n\n", with: "\n")
    }
}

/// Every bot's recent turns, newest first: the "what is everyone doing" view.
struct FeedView: View {
    @Environment(AppStore.self) private var store
    @Environment(LensStore.self) private var lens

    private var working: [LensTurn] { lens.feed.filter(\.open) }
    private var recent: [LensTurn] { lens.feed.filter { !$0.open } }

    var body: some View {
        NavigationStack {
            List {
                if !working.isEmpty {
                    Section("Working now") { rows(working) }
                }
                if !recent.isEmpty {
                    Section("Recent") { rows(recent) }
                }
            }
            .listStyle(.insetGrouped)
            .overlay { if lens.feed.isEmpty { LensEmptyState() } }
            .safeAreaInset(edge: .top, spacing: 0) { ConnectionBanner() }
            .refreshable { await lens.refresh() }
            .navigationTitle("Activity")
            .navigationDestination(for: TurnLink.self) { TurnDetailView(botId: $0.botId, turnId: $0.turnId) }
        }
    }

    private func rows(_ turns: [LensTurn]) -> some View {
        ForEach(turns) { turn in
            NavigationLink(value: TurnLink(botId: turn.botId ?? "", turnId: turn.id)) {
                TurnCard(turn: turn, showBot: true)
            }
        }
    }
}

struct TurnLink: Hashable {
    let botId: String
    let turnId: String
}

/// One bot's turns, newest first, with older ones on demand.
struct BotActivityView: View {
    @Environment(AppStore.self) private var store
    @Environment(LensStore.self) private var lens
    let botId: String
    @State private var turns: [LensTurn] = []
    @State private var hasMore = false
    @State private var loaded = false

    var body: some View {
        List {
            ForEach(turns) { turn in
                NavigationLink(value: TurnLink(botId: botId, turnId: turn.id)) { TurnCard(turn: turn, botIdFallback: botId) }
            }
            if hasMore {
                Button("Load earlier turns") { Task { await loadMore() } }
            }
        }
        .listStyle(.plain)
        .overlay { if loaded, turns.isEmpty { LensEmptyState() } }
        .refreshable { await reload() }
        // Pick up new turns as the latest one moves on.
        .task(id: lens.latest[botId]) { await reload() }
    }

    private func reload() async {
        guard let page = try? await lens.turns(bot: botId) else { loaded = true; return }
        if turns.count > page.turns.count {
            // Earlier pages were loaded: keep them under the fresh first page.
            let fresh = Set(page.turns.map(\.id))
            turns = page.turns + turns.filter { !fresh.contains($0.id) }
        } else {
            turns = page.turns
            hasMore = page.hasMore
        }
        loaded = true
    }

    private func loadMore() async {
        guard let last = turns.last, let page = try? await lens.turns(bot: botId, before: last.id) else { return }
        turns += page.turns
        hasMore = page.hasMore
    }
}

struct LensEmptyState: View {
    @Environment(LensStore.self) private var lens

    var body: some View {
        switch lens.status {
        case .unknown:
            ProgressView()
        case .unreachable:
            ContentUnavailableView {
                Label("Gravity Lens not reachable", systemImage: "eye.slash")
            } description: {
                Text("The activity view needs the Gravity Lens companion running on the Mac, on port \(String(lens.port)). See the README in the GravitiOS project.")
            }
        case .unauthorized:
            ContentUnavailableView("Token rejected", systemImage: "lock",
                                   description: Text("Gravity Lens checks the same device token as the daemon. It needs the read grant."))
        case .ok:
            ContentUnavailableView("Nothing yet", systemImage: "text.bubble",
                                   description: Text("Turns appear here as the bots work."))
        }
    }
}
