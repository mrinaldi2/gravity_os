import SwiftUI

// UX-024: the app opens on Projects, ranked by how much each needs you, and
// Needs you gathers what is waiting across projects. Both span every
// computer and show the last answer at once.

/// A project to open from the home, on the computer that answered for it.
struct HomeProjectLink: Hashable {
    let computerId: String
    let projectId: String
}

/// Where a Needs-you row leads.
enum NeedsDestination: Hashable {
    case decision(computerId: String, decisionId: String)
    case bot(computerId: String, botId: String, chat: Bool)
    case note(title: String, text: String)
}

extension ReleaseStatusWords {
    static func pill(_ release: Hermes_Home_V1_ReleaseBrief) -> (String, Tone) {
        let version = release.version.isEmpty ? "Release" : release.version
        switch release.state {
        case "awaiting_owner": return ("\(version) ready for you to test", .needsYou)
        case "deployed": return ("\(version) live", .ready)
        case "held": return ("\(version) on hold", .quiet)
        case "approved": return ("\(version) approved", .ready)
        case "deploying", "partially_deployed": return ("\(version) rolling out", .working)
        case "paused": return ("\(version) rollout paused", .needsYou)
        case "rejected": return ("\(version) rejected", .failed)
        case "rolled_back": return ("\(version) rolled back", .failed)
        case "assembling", "built", "repackaging": return ("\(version) being packaged", .working)
        default: return (version, .quiet)
        }
    }
}

/// Release states in the glossary's words (§5).
enum ReleaseStatusWords {}

// MARK: Projects

struct ProjectsHomeView: View {
    @Environment(Fleet.self) private var fleet
    @State private var path = NavigationPath()
    /// Set from outside (a notification, Needs you): opens that project.
    var openProject: Binding<HomeProjectLink?> = .constant(nil)

    private var feed: HomeFeed { fleet.home }
    private var cards: [HomeCard] { feed.cards(fleet.computers) }
    /// Changes whenever a computer connects or drops, to refetch.
    private var connections: String { fleet.computers.map { "\($0.id)=\($0.store.status == .connected)" }.joined(separator: ",") }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if cards.isEmpty {
                    EmptyNote(text: fleet.computers.contains { $0.store.status == .connected }
                              ? "No projects yet" : "Connecting…", systemImage: "folder")
                }
                ForEach(cards) { card in
                    Section {
                        NavigationLink(value: HomeProjectLink(computerId: card.computerId, projectId: card.row.projectID)) {
                            ProjectCard(card: card)
                        }
                        .contextMenu { pinButton(card) }
                        // The project that needs you most is outlined (UX-024).
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(.secondarySystemGroupedBackground))
                                .overlay {
                                    if card.rank == 1 {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange, lineWidth: 2)
                                    }
                                }
                        )
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(10)
            .navigationTitle("Projects")
            .refreshable { await feed.refreshAll(fleet.computers, force: true) }
            .task(id: connections) {
                feed.loadCache(fleet.computers)
                #if DEBUG
                feed.loadFixture(fleet.computers)
                #endif
                await feed.refreshAll(fleet.computers)
            }
            .navigationDestination(for: HomeProjectLink.self) { link in
                if let computer = fleet.computers.first(where: { $0.id == link.computerId }) {
                    ProjectView(projectId: link.projectId).computerEnvironment(computer)
                }
            }
            .onChange(of: openProject.wrappedValue, initial: true) { _, link in
                guard let link else { return }
                path = NavigationPath([link])
                openProject.wrappedValue = nil
            }
        }
    }

    @ViewBuilder private func pinButton(_ card: HomeCard) -> some View {
        if let computer = fleet.computers.first(where: { $0.id == card.computerId }), computer.store.canPin {
            Button(card.row.pinned ? "Unpin" : "Pin to top", systemImage: card.row.pinned ? "pin.slash" : "pin") {
                Task {
                    try? await computer.store.pinProject(card.row.projectID, pinned: !card.row.pinned)
                    await feed.refresh(computer, force: true)
                }
            }
        }
    }
}

/// One project on the home: why it ranks, its release, what is running, the
/// lead's latest word.
struct ProjectCard: View {
    let card: HomeCard

    private var row: HomeRow { card.row }
    private var waiting: Bool { row.attention.count > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                RankBadge(rank: card.rank)
                Text(row.name).font(.headline).lineLimit(1)
                if row.pinned {
                    Image(systemName: "pin.fill").font(.caption).foregroundStyle(Color.secondaryText)
                        .accessibilityLabel("Pinned")
                }
            }
            Text(AttentionWords.summary(row.attention))
                .font(.subheadline.weight(waiting ? .medium : .regular))
                .foregroundStyle(waiting ? Color.warningText : Color.secondaryText)
            if row.hasCurrentRelease {
                let (text, tone) = ReleaseStatusWords.pill(row.currentRelease)
                Pill(text: text, tone: tone)
            }
            Text(running).font(.subheadline).foregroundStyle(Color.secondaryText)
            if row.hasLatestSummary, !row.latestSummary.text.isEmpty {
                Text("“\(row.latestSummary.text)”").font(.subheadline).lineLimit(2)
            }
            if row.legacy {
                Label("Update needed for full info", systemImage: "arrow.up.circle")
                    .font(.footnote).foregroundStyle(Color.secondaryText)
            } else if !card.staleNames.isEmpty {
                Label(staleLine, systemImage: "wifi.slash").font(.footnote).foregroundStyle(Color.secondaryText)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// "5 tasks running · 8 bots, 5 working, 1 waiting for you".
    private var running: String {
        var parts: [String] = []
        if row.openTasks > 0 { parts.append("\(row.openTasks) task\(row.openTasks == 1 ? "" : "s") running") }
        var bots = "\(row.bots) bot\(row.bots == 1 ? "" : "s")"
        if row.botsWorking > 0 { bots += ", \(row.botsWorking) working" }
        if row.botsWaiting > 0 { bots += ", \(row.botsWaiting) waiting for you" }
        if row.bots > 0, row.botsWorking == 0, row.botsWaiting == 0 { bots += ", idle" }
        parts.append(bots)
        return parts.joined(separator: " · ")
    }

    /// "imac away · as of 10:42".
    private var staleLine: String {
        let names = ListFormatter.localizedString(byJoining: card.staleNames)
        guard let since = card.staleSince else { return "\(names) away" }
        return "\(names) away · as of \(since.formatted(date: .omitted, time: .shortened))"
    }
}

/// "#1": the project's place by how much it needs you; a dash when nothing does.
struct RankBadge: View {
    let rank: Int?

    var body: some View {
        Text(rank.map { "#\($0)" } ?? "—")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(rank == nil ? Color.secondaryText : Color.warningText)
            .background((rank == nil ? Tone.quiet : Tone.needsYou).color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel(rank.map { "Rank \($0)" } ?? "Nothing needs you")
    }
}

// MARK: Needs you

struct NeedsYouView: View {
    @Environment(Fleet.self) private var fleet
    @State private var path = NavigationPath()
    @State private var showingDecisions = false
    /// Set from outside, e.g. a notification: opens that decision.
    var openDecision: Binding<NeedsDestination?> = .constant(nil)

    private var feed: HomeFeed { fleet.home }
    private var waiting: [HomeCard] { feed.cards(fleet.computers).filter { $0.row.attention.count > 0 } }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if waiting.isEmpty {
                    EmptyNote(text: "Nothing is waiting on you.", systemImage: "checkmark.circle")
                }
                ForEach(waiting) { card in
                    Section {
                        let rows = feed.attention[card.id] ?? []
                        if rows.isEmpty {
                            Text(AttentionWords.summary(card.row.attention, limit: 5))
                                .font(.subheadline).foregroundStyle(Color.secondaryText)
                        }
                        ForEach(rows, id: \.id) { row in
                            NavigationLink(value: destination(row, card: card)) { NeedsRow(row: row) }
                        }
                    } header: {
                        SectionTitle(card.rank.map { "\(card.row.name) · #\($0)" } ?? card.row.name)
                    }
                    .task(id: "\(card.id)/\(card.row.attention.count)/\(card.row.attention.score)") {
                        if let computer = computer(card.computerId) { await feed.loadAttention(card, on: computer) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Needs you")
            .toolbar {
                // Every decision, settled ones too (UX-024: Needs you → Decisions).
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Decisions") { showingDecisions = true }
                }
            }
            .sheet(isPresented: $showingDecisions) { DecisionsView(openDecision: .constant(nil)) }
            .refreshable { await feed.refreshAll(fleet.computers, force: true) }
            .navigationDestination(for: NeedsDestination.self) { destination in
                switch destination {
                case .decision(let computerId, let decisionId):
                    if let computer = computer(computerId) {
                        DecisionDetailView(decisionId: decisionId).computerEnvironment(computer)
                    }
                case .bot(let computerId, let botId, let chat):
                    if let computer = computer(computerId) {
                        BotDetailView(botId: botId, initialPane: chat ? .chat : nil).computerEnvironment(computer)
                    }
                case .note(let title, let text):
                    NeedsNote(title: title, text: text)
                }
            }
            .onChange(of: openDecision.wrappedValue, initial: true) { _, destination in
                guard let destination else { return }
                path = NavigationPath([destination])
                openDecision.wrappedValue = nil
            }
        }
    }

    private func computer(_ id: String) -> Computer? { fleet.computers.first { $0.id == id } }

    /// The computer that acts on a row, by its daemon id; else the one that answered.
    private func actor(_ daemonId: String, card: HomeCard) -> Computer? {
        fleet.computers.first { $0.store.daemonId == daemonId && !daemonId.isEmpty } ?? computer(card.computerId)
    }

    private func destination(_ row: HomeAttentionRow, card: HomeCard) -> NeedsDestination {
        let on = actor(row.daemonID, card: card)
        let place = on?.name ?? "that computer"
        switch row.target {
        case .decisionID(let id)?:
            if let on { return .decision(computerId: on.id, decisionId: id) }
        case .requestID(let id)?:
            if let on, let bot = on.store.permissions.first(where: { $0.id == id })?.botId {
                return .bot(computerId: on.id, botId: bot, chat: false)
            }
            return .note(title: row.title, text: "Answer it on \(place), in The Hermes app.")
        case .bot(let ref)?:
            if let botComputer = fleet.computers.first(where: { $0.store.daemonId == ref.daemonID }) ?? on {
                return .bot(computerId: botComputer.id, botId: ref.botID, chat: true)
            }
        case .releaseID?:
            return .note(title: row.title, text: "The release review comes to the phone in the next build. Review it on the desktop for now.")
        case .actionID?:
            return .note(title: row.title, text: "Run cards come to the phone in this release. For now, run or reject it on \(place), in The Hermes app.")
        case .itemID(let id)?:
            return .note(title: row.title, text: "Open \(id) on the desktop board to answer it.")
        case nil:
            break
        }
        switch row.kind {
        case .relayedRulings:
            return .note(title: row.title, text: "Confirm them under Decisions on \(place).")
        case .servingOff:
            return .note(title: row.title, text: "\(place) isn't serving the phone securely. Check it in Settings → Computers.")
        default:
            return .note(title: row.title, text: "Open it on \(place).")
        }
    }
}

/// One thing waiting: what it is and how long it has waited.
struct NeedsRow: View {
    let row: HomeAttentionRow

    var body: some View {
        ItemRow(title: row.title, subtitle: subtitle, titleLines: 2) {
            IconTile(systemImage: symbol, tone: tone)
        }
    }

    private var subtitle: String {
        var parts = [kindWord]
        if row.hasCreatedAt { parts.append(row.createdAt.date.relative) }
        return parts.joined(separator: " · ")
    }

    private var kindWord: String {
        switch row.kind {
        case .releaseAwaiting: "Release to test"
        case .ownerAction: "Run card"
        case .permissionPrompt: "Permission request"
        case .decision: row.priority == "urgent" || row.priority == "P0" ? "Urgent decision" : "Decision"
        case .relayedRulings: "Rulings to confirm"
        case .p0Item: "P0 item"
        case .botWaiting: "Waiting for you"
        case .offBoard: "Off the board"
        case .servingOff: "Not serving"
        case .ownerQuestion: "Question"
        default: "Needs you"
        }
    }

    private var symbol: String {
        switch row.kind {
        case .releaseAwaiting: "shippingbox.fill"
        case .ownerAction: "terminal.fill"
        case .permissionPrompt: "hand.raised.fill"
        case .decision: "checklist"
        case .relayedRulings: "checkmark.seal"
        case .p0Item: "exclamationmark.triangle.fill"
        case .botWaiting: "person.crop.circle.badge.clock"
        case .offBoard: "rectangle.dashed"
        case .servingOff: "wifi.slash"
        case .ownerQuestion: "questionmark.bubble.fill"
        default: "circle"
        }
    }

    private var tone: Tone {
        switch row.kind {
        case .p0Item, .servingOff: .failed
        case .decision where row.priority == "urgent" || row.priority == "P0": .failed
        case .relayedRulings, .offBoard: .quiet
        case .ownerQuestion: .working
        default: .needsYou
        }
    }
}

/// A row the phone can't act on yet: says where to.
struct NeedsNote: View {
    let title: String
    let text: String

    var body: some View {
        List {
            Section {
                Text(title).font(.headline)
                Text(text).foregroundStyle(Color.secondaryText)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Needs you")
        .navigationBarTitleDisplayMode(.inline)
    }
}
