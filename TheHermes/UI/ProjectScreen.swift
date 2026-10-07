import SwiftUI

// UX-024: a project opens on its Overview; Board and Team follow, then
// Releases and Meetings. Board, releases and meetings come from the board's
// home; bots from the computer that answered (H-128 R2.1).

struct ProjectScreen: View {
    @Environment(Fleet.self) private var fleet
    @Environment(AppStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    let projectId: String
    @State private var segment = Segment.overview
    @State private var showingArtifacts = false

    enum Segment: String, CaseIterable {
        case overview = "Overview", board = "Board", team = "Team", releases = "Releases", meetings = "Meetings"
    }

    private var project: Project? { store.projects.first { $0.id == projectId } }
    private var name: String { project?.name ?? card?.row.name ?? "Project" }

    /// The computer that keeps the board (UX-029): the board home's member name.
    private var boardHomeName: String? {
        guard let card else { return nil }
        return card.row.members.first { $0.daemonID == card.row.boardHome }?.computerName.nilIfEmpty
    }

    /// "▲ 4 need you" and the release pill under the name, as on desktop (U2).
    @ViewBuilder private var header: some View {
        let waiting = Int(card?.row.attention.count ?? 0)
        let release = card?.row.hasCurrentRelease == true ? card?.row.currentRelease : nil
        if sizeClass == .regular || waiting > 0 || release != nil {
            VStack(alignment: .leading, spacing: 6) {
                if sizeClass == .regular {
                    Text(name).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                }
                HStack(spacing: 6) {
                    if waiting > 0 { Pill(text: "▲ \(waiting) need you", tone: .needsYou) }
                    if let release {
                        let (text, tone) = ReleaseStatusWords.pill(release)
                        Pill(text: text, tone: tone)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    /// This project's card on the home, for its members and board home.
    private var card: HomeCard? {
        fleet.home.cards(fleet.computers).first { card in
            card.row.projectID == projectId || card.row.members.contains { $0.projectID == projectId && $0.daemonID == store.daemonId }
        }
    }

    /// The board's home and the project's id there, when the phone talks to
    /// it; else this computer, which mirrors or forwards.
    private var home: (computer: Computer, projectId: String)? {
        if let card, let computer = fleet.computer(daemonId: card.row.boardHome),
           let member = card.row.members.first(where: { $0.daemonID == card.row.boardHome }) {
            return (computer, member.projectID)
        }
        return fleet.computers.first { $0.store === store }.map { ($0, projectId) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Picker("Section", selection: $segment) {
                ForEach(Segment.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            Group {
                switch segment {
                case .overview: OverviewPane(projectId: projectId, card: card, home: home)
                case .board: BoardPane(home: home, homeName: boardHomeName)
                case .team: TeamPane(projectId: projectId)
                case .releases: ReleasesPane(home: home)
                case .meetings: MeetingsPane(home: home)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(sizeClass == .regular ? "" : name)
        // iPad's detail column draws no large title, so the header carries the name (UX-029).
        .navigationBarTitleDisplayMode(sizeClass == .regular ? .inline : .large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Artifacts", systemImage: "doc.on.doc") { showingArtifacts = true }
                    NavigationLink { ConversationsView(projectId: projectId) } label: {
                        Label("Conversations", systemImage: "bubble.left.and.bubble.right")
                    }
                    NavigationLink { ProjectView(projectId: projectId) } label: {
                        Label("Project settings", systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
            }
        }
        .sheet(isPresented: $showingArtifacts) { ReportsView() }
        #if DEBUG
        .task {
            if let name = UserDefaults.standard.string(forKey: "openSegment"),
               let chosen = Segment.allCases.first(where: { $0.rawValue.lowercased().hasPrefix(name.lowercased()) }) {
                segment = chosen
            }
        }
        #endif
    }
}

/// Words for a board kept on another computer (UX-029).
enum BoardWords {
    static func elsewhere(_ home: String?) -> String {
        "This project's board is kept on \(home ?? "another computer"). Open it there, or link this computer to see it here."
    }

    /// The service's "not the board's home here" answers.
    static func isElsewhere(_ error: Error) -> Bool {
        if let error = error as? DaemonError, ["no_board", "not_home", "elsewhere"].contains(error.code) { return true }
        let text = error.localizedDescription.lowercased()
        return text.contains("linked with another computer") || text.contains("open it there")
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: Overview

struct OverviewPane: View {
    @Environment(Fleet.self) private var fleet
    let projectId: String
    let card: HomeCard?
    let home: (computer: Computer, projectId: String)?
    @State private var dashboard: Dashboard?
    @State private var failure: String?

    /// An older service's rows are read live from its store, which fills in after connect.
    private var needs: [HomeAttentionRow] {
        guard let card else { return [] }
        if let computer = fleet.computer(id: card.computerId), card.row.legacy || !computer.store.hasHome {
            return computer.store.legacyAttention(projectId: card.row.projectID)
        }
        return fleet.home.attention[card.id] ?? []
    }

    var body: some View {
        List {
            if let card, card.row.attention.count > 0 {
                Section {
                    if needs.isEmpty {
                        Text(AttentionWords.summary(card.row.attention, limit: 5)).foregroundStyle(Color.secondaryText)
                    }
                    // Up to 5 here; the rest wait in Needs you (UX-029).
                    ForEach(needs.prefix(5), id: \.id) { row in
                        NavigationLink(value: fleet.needsDestination(row, answeredBy: card.computerId)) { NeedsRow(row: row) }
                            .cardMenu(for: row.itemIdText)
                    }
                    let total = max(Int(card.row.attention.count), needs.count)
                    if total > 5 {
                        Button("See all \(total) in Needs you ›") { fleet.home.needsFocus = card.id }
                            .font(.subheadline.weight(.semibold))
                    }
                } header: {
                    SectionTitle("Needs you", count: Int(card.row.attention.count))
                }
            }
            Section {
                if let summary = card?.row.latestSummary, !summary.text.isEmpty {
                    ItemRow(title: "Latest summary", subtitle: summary.text, detail: summary.hasAt ? summary.at.date.relative : nil,
                            subtitleLines: 4) { IconTile(systemImage: "text.quote", tone: .working) }
                }
                ForEach(dashboard?.meetings.filter { $0.lastSummary != nil } ?? []) { meeting in
                    ItemRow(title: "\(meeting.name) minutes", subtitle: meeting.lastSummary, detail: meeting.lastHeldAt?.relative,
                            subtitleLines: 3) { IconTile(systemImage: "person.3") }
                }
                if card?.row.hasLatestSummary != true, dashboard?.meetings.contains(where: { $0.lastSummary != nil }) != true {
                    EmptyNote(text: "Nothing reported yet", systemImage: "text.quote")
                }
            } header: {
                SectionTitle("From the team")
            }
            if let dashboard, dashboard.hasBoard {
                Section {
                    Text(stripLine(dashboard)).font(.subheadline)
                    if dashboard.blocked > 0 || dashboard.stale > 0 {
                        Text([dashboard.blocked > 0 ? "\(dashboard.blocked) blocked" : nil,
                              dashboard.stale > 0 ? "\(dashboard.stale) stale" : nil].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(Color.warningText)
                    }
                    if let done = dashboard.doneThisWeek {
                        Text("This week: \(done) done, \(dashboard.reworkThisWeek ?? 0) sent back")
                            .font(.footnote).foregroundStyle(Color.secondaryText)
                    }
                } header: {
                    SectionTitle("Board")
                }
            }
            if let release = dashboard?.releases.first, let home {
                Section {
                    NavigationLink(value: NeedsDestination.release(computerId: home.computer.id, releaseId: release.id)) {
                        ReleaseRow(release: release)
                    }
                } header: {
                    SectionTitle("Release")
                }
            }
            if let actions = dashboard?.actions, !actions.isEmpty {
                Section {
                    ForEach(actions) { action in
                        ItemRow(title: action.text, subtitle: actionLine(action)) {
                            IconTile(systemImage: "checkmark.circle", tone: action.overdue ? .needsYou : nil)
                        }
                    }
                } header: {
                    SectionTitle("Action items", count: actions.count)
                }
            }
            if let failure {
                Text(failure).font(.footnote).foregroundStyle(Color.errorText)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
        .task(id: home?.computer.store.status == .connected) { await load() }
    }

    private func load() async {
        if let card, let computer = fleet.computer(id: card.computerId) { await fleet.home.loadAttention(card, on: computer) }
        guard let home else { return }
        do {
            dashboard = try await home.computer.store.dashboard(projectId: home.projectId)
            failure = nil
        } catch {
            failure = "Couldn’t load the overview. \(error.localizedDescription)"
        }
    }

    /// "Doing 3 · Review 2/3 · Verify 3/3 full".
    private func stripLine(_ dashboard: Dashboard) -> String {
        let strip = dashboard.strip
        guard !strip.isEmpty else { return "No cards in progress" }
        return strip.map { column in
            let count = column.wipLimit.map { "\(column.count)/\($0)" } ?? "\(column.count)"
            return "\(column.name) \(count)\(column.full ? " full" : "")"
        }.joined(separator: " · ")
    }

    private func actionLine(_ action: Dashboard.Action) -> String {
        var parts: [String] = []
        if let meeting = action.meetingName { parts.append(meeting) }
        if let due = action.dueAt { parts.append((action.overdue ? "Overdue since " : "Due ") + due.formatted(date: .abbreviated, time: .omitted)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: Board

struct BoardPane: View {
    let home: (computer: Computer, projectId: String)?
    /// The computer that keeps this project's board, for when this one can't show it.
    var homeName: String?
    @State private var board: BoardSnapshot?
    @State private var failure: String?
    @State private var column = ""
    /// The service answered that this computer doesn't keep the board.
    @State private var elsewhere = false

    private var columns: [Hermes_Board_V1_BoardColumn] { board?.columns.filter(\.visible) ?? [] }

    var body: some View {
        Group {
            if let home, !home.computer.store.speaksProto {
                ContentUnavailableView("Board needs an update", systemImage: "arrow.up.circle",
                                       description: Text("Update The Hermes on \(home.computer.name) to see the board here."))
            } else if let board, !columns.isEmpty {
                VStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(columns, id: \.key) { column in
                                let count = board.cards.filter { $0.columnKey == column.key }.count
                                Button { self.column = column.key } label: {
                                    Text(column.hasWipLimit ? "\(column.name) \(count)/\(column.wipLimit)" : "\(column.name) \(count)")
                                        .font(.subheadline.weight(self.column == column.key ? .semibold : .regular))
                                        .padding(.horizontal, 12)
                                        .frame(minHeight: 36)
                                        .background(self.column == column.key ? Color.accentColor.opacity(0.15) : Color(.tertiarySystemFill),
                                                    in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.bottom, 6)
                    TabView(selection: $column) {
                        ForEach(columns, id: \.key) { column in
                            ColumnList(cards: board.cards.filter { $0.columnKey == column.key }, computerId: home?.computer.id ?? "",
                                       bots: home?.computer.store.bots ?? [])
                                .tag(column.key)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
            } else if elsewhere {
                // UX-029: where the board lives, not the service's instruction.
                ContentUnavailableView("Board on another computer", systemImage: "rectangle.split.3x1",
                                       description: Text(BoardWords.elsewhere(homeName)))
            } else if let failure {
                ContentUnavailableView("Couldn’t load the board", systemImage: "exclamationmark.triangle", description: Text(failure))
            } else if board != nil {
                ContentUnavailableView("No board yet", systemImage: "rectangle.split.3x1")
            } else {
                ProgressView()
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let home, home.computer.store.speaksProto else { return }
        do {
            let snapshot = try await home.computer.store.board(projectId: home.projectId)
            board = snapshot
            if column.isEmpty {
                // Open on the first column with cards in progress.
                column = snapshot.columns.first { c in c.visible && c.category == .doing }?.key ?? snapshot.columns.first(where: \.visible)?.key ?? ""
            }
            failure = nil
        } catch {
            elsewhere = BoardWords.isElsewhere(error)
            failure = error.localizedDescription
        }
    }
}

/// One column's cards, in board order.
struct ColumnList: View {
    let cards: [BoardCard]
    let computerId: String
    let bots: [Bot]

    var body: some View {
        List {
            if cards.isEmpty { EmptyNote(text: "No cards here", systemImage: "tray") }
            ForEach(cards, id: \.id) { card in
                NavigationLink(value: NeedsDestination.item(computerId: computerId, itemId: card.id)) {
                    ItemRow(title: card.title, subtitle: subtitle(card), titleLines: 2) {
                        IconTile(systemImage: card.blocked ? "nosign" : "square.text.square", tone: card.blocked ? .failed : nil)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func subtitle(_ card: BoardCard) -> String {
        var parts = [card.id]
        if card.hasAssignee, let name = bots.first(where: { $0.id == card.assignee })?.name { parts.append(name) }
        if card.acTotal > 0 { parts.append("\(card.acChecked)/\(card.acTotal) criteria") }
        if card.blocked { parts.append("Blocked") }
        if card.stale { parts.append("Stale") }
        return parts.joined(separator: " · ")
    }
}

/// A card in full: description, criteria and comments; the owner can comment.
struct ItemView: View {
    @Environment(Fleet.self) private var fleet
    @Environment(AppStore.self) private var store
    let itemId: String
    @State private var detail: BoardItemDetail?
    @State private var draft = ""
    /// What this device posted (H-202): shown at once, then confirmed or failed.
    @State private var pending: [PendingComment] = []
    @State private var replyTo: CommentRow?
    @State private var failure: String?
    @FocusState private var composing: Bool

    private var groups: [CommentGroup] {
        CommentThread.grouped(CommentThread.rows(comments: detail?.comments ?? [], history: detail?.history ?? [],
                                                 pending: pending))
    }

    var body: some View {
        List {
            if let item = detail?.item {
                Section {
                    Text(item.title).font(.headline)
                    // Where the card stands (UX-037): "Doing · Desktop Dev", flags.
                    let facts = CardPreview.of(item) { store.bot($0)?.name }
                    if let place = facts.placeLine { Text(place).font(.subheadline) }
                    if let flags = facts.flagsLine { Text(flags).font(.subheadline).foregroundStyle(Color.warningText) }
                    if !item.description_p.isEmpty {
                        Text(fleet.linkedText(item.description_p)).font(.callout)
                            .cardMenu(for: item.description_p)
                    }
                } header: {
                    // The id is the navigation title; the header says what kind of card it is.
                    if let kind = CardPreview.of(item, botName: { _ in nil }).kindLine { SectionTitle(kind) }
                }
                if !item.acceptanceCriteria.isEmpty {
                    Section {
                        ForEach(item.acceptanceCriteria, id: \.idx) { criterion in
                            Label(criterion.text, systemImage: criterion.checked ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(criterion.checked ? Color.successText : Color.primary)
                        }
                    } header: {
                        SectionTitle("Acceptance criteria")
                    }
                }
                Section {
                    if groups.isEmpty { EmptyNote(text: "No comments yet", systemImage: "text.bubble") }
                    ForEach(groups) { group in
                        commentRow(group.comment, reply: false)
                        ForEach(group.replies) { commentRow($0, reply: true) }
                    }
                    if store.canControl { composer }
                } header: {
                    SectionTitle("Comments")
                }
            } else if let failure {
                Text(failure).foregroundStyle(Color.errorText)
            } else {
                ProgressView()
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(itemId)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    @ViewBuilder private func commentRow(_ row: CommentRow, reply: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if reply { Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(Color.secondaryText) }
                Text(author(row.author)).font(.caption.weight(.semibold))
                if let at = row.at { Text(at.relative).font(.caption2).foregroundStyle(Color.secondaryText) }
                Spacer(minLength: 4)
                statusLabel(row)
            }
            Group {
                if let body = row.body {
                    Text(fleet.linkedText(body)).cardMenu(for: body)
                } else {
                    Text("A comment. Its text shows once the Hermes service on \(store.computerName.isEmpty ? "your computer" : store.computerName) is updated.")
                        .foregroundStyle(Color.secondaryText)
                }
            }
            .font(.callout)
            .textSelection(.enabled)
            if case .failed(let message) = row.status {
                HStack(spacing: 12) {
                    Text(message).font(.caption).foregroundStyle(Color.errorText)
                    if let id = row.pendingId {
                        // Caption-sized words, 44 pt targets.
                        Button("Retry") { retry(id) }.font(.caption.weight(.semibold))
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                        Button("Discard", role: .destructive) { pending.removeAll { $0.id == id } }.font(.caption)
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                }
                .buttonStyle(.borderless)
            } else if row.status == .onBoard, store.canControl, !reply {
                Button("Reply") {
                    replyTo = row
                    composing = true
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
            }
        }
        .padding(.leading, reply ? 16 : 0)
        .padding(.vertical, 2)
    }

    @ViewBuilder private func statusLabel(_ row: CommentRow) -> some View {
        switch row.status {
        case .onBoard: EmptyView()
        case .sending:
            Label("Sending…", systemImage: "clock").font(.caption2).foregroundStyle(Color.secondaryText)
        case .sent:
            Label("Posted", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(Color.successText)
        case .failed:
            Label("Not posted", systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(Color.errorText)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let replyTo {
                HStack {
                    Text(CommentWords.replying(to: replyTo.author) { author($0) }).font(.caption).foregroundStyle(Color.secondaryText)
                    Button("Cancel") { self.replyTo = nil }.font(.caption).buttonStyle(.borderless)
                }
            }
            HStack(alignment: .bottom) {
                TextField("Comment", text: $draft, prompt: .placeholder(replyTo == nil ? "Comment on \(itemId)" : "Reply"), axis: .vertical)
                    .lineLimit(1...6)
                    .focused($composing)
                Button("Send") { post() }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(.borderless)
            }
        }
    }

    private func author(_ actor: String) -> String {
        CommentWords.author(actor) { store.bot($0)?.name }
    }

    private func load() async {
        do {
            let fresh = try await store.item(itemId)
            detail = fresh
            pending = CommentThread.stillPending(pending, comments: fresh.comments)
            failure = nil
        } catch {
            if detail == nil { failure = error.localizedDescription }
        }
    }

    /// Shows the comment at once, then sends it.
    private func post() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let comment = PendingComment(body: body, replyTo: replyTo?.status == .onBoard ? replyTo?.id : nil)
        pending.append(comment)
        draft = ""
        replyTo = nil
        send(comment.id)
    }

    private func retry(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[index].state = .sending
        send(id)
    }

    private func send(_ id: UUID) {
        guard let comment = pending.first(where: { $0.id == id }) else { return }
        Task {
            do {
                try await store.postComment(on: itemId, comment.body, replyTo: comment.replyTo)
                if let index = pending.firstIndex(where: { $0.id == id }) {
                    pending[index].state = .sent
                    pending[index].sentAt = Date()
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                await load()
                // "✓ Posted" shows on the board's copy, then goes (QA-006).
                try? await Task.sleep(for: .seconds(CommentThread.postedFor))
                pending = CommentThread.stillPending(pending, comments: detail?.comments ?? [])
            } catch {
                if let index = pending.firstIndex(where: { $0.id == id }) {
                    pending[index].state = .failed(error.localizedDescription)
                }
            }
        }
    }
}

// MARK: Team

struct TeamPane: View {
    @Environment(AppStore.self) private var store
    @Environment(Fleet.self) private var fleet
    let projectId: String

    private var bots: [Bot] {
        guard let project = store.projects.first(where: { $0.id == projectId }) else { return [] }
        return store.bots(in: project)
    }

    var body: some View {
        List {
            if bots.isEmpty { EmptyNote(text: "No bots yet", systemImage: "person") }
            ForEach(bots) { bot in
                NavigationLink(value: NeedsDestination.bot(computerId: fleet.computers.first { $0.store === store }?.id ?? "", botId: bot.id, chat: false)) {
                    // With owner threads, the thread is the truth: no thread, nothing unread.
                    BotRow(bot: bot, unread: store.hasOwnerThreads ? (threadsLoaded ? (unread[bot.id] ?? 0) : 0) : nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        // How many of each bot's messages to you are unread (owner threads).
        .task(id: store.ownerThreadsVersion) {
            guard store.hasOwnerThreads, let threads = try? await store.ownerThreads() else { return }
            unread = Dictionary(threads.map { ($0.bot.botID, Int($0.unread)) }, uniquingKeysWith: max)
            threadsLoaded = true
        }
    }

    @State private var unread: [String: Int] = [:]
    @State private var threadsLoaded = false
}

// MARK: Releases

struct ReleaseRow: View {
    let release: Release

    var body: some View {
        let (words, tone) = release.statusWords
        ItemRow(title: release.version, subtitle: release.itemsTotal > 0 ? "\(release.itemsReady) of \(release.itemsTotal) items ready" : nil) {
            IconTile(systemImage: "shippingbox", tone: tone)
        } trailing: {
            Pill(text: words.replacingOccurrences(of: release.version + " ", with: "").capitalizedFirst, tone: tone)
        }
    }
}

struct ReleasesPane: View {
    let home: (computer: Computer, projectId: String)?
    @State private var releases: [Release]?
    @State private var failure: String?

    var body: some View {
        List {
            if let releases {
                if releases.isEmpty { EmptyNote(text: "No releases yet", systemImage: "shippingbox") }
                ForEach(releases) { release in
                    NavigationLink(value: NeedsDestination.release(computerId: home?.computer.id ?? "", releaseId: release.id)) {
                        ReleaseRow(release: release)
                    }
                }
            } else if let failure {
                Text(failure).foregroundStyle(Color.errorText)
            } else {
                ProgressView()
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard let home else { return }
        do { releases = try await home.computer.store.releases(projectId: home.projectId) } catch { failure = error.localizedDescription }
    }
}

/// A package: where it stands, its items and tests. Ruling on it comes with the release review.
struct ReleaseView: View {
    @Environment(Fleet.self) private var fleet
    @Environment(AppStore.self) private var store
    let releaseId: String
    @State private var release: Release?
    @State private var failure: String?

    /// The computer this release was read from.
    private var computerId: String { fleet.computers.first { $0.store === store }?.id ?? "" }

    var body: some View {
        List {
            if let release {
                Section {
                    let (words, tone) = release.statusWords
                    Pill(text: words, tone: tone)
                    if let changelog = release.changelog, !changelog.isEmpty {
                        Text(fleet.linkedText(changelog)).font(.callout)
                            .cardMenu(for: changelog)
                    }
                    Text(release.canRule
                         ? "Ruling on a release from the phone comes with the release review. Approve, hold or reject it on the desktop for now."
                         : "Rule on it on \(release.ruleOn ?? "the board's home computer"), in The Hermes app.")
                        .font(.footnote).foregroundStyle(Color.secondaryText)
                }
                Section {
                    // Each item's real state (H-200): its board state before the
                    // package is submitted, the owner's ruling after.
                    ForEach(release.items) { item in
                        let state = release.state(of: item) { store.bot($0)?.name }
                        // The row is the card: tap opens it, long-press previews it (H-204).
                        NavigationLink(value: NeedsDestination.item(computerId: fleet.cards.home(for: item.itemId)?.computerId ?? computerId,
                                                                    itemId: item.itemId)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(state.title).font(.subheadline.weight(.medium)).lineLimit(3)
                            if let meta = state.meta {
                                Text(meta).font(.caption).foregroundStyle(Color.secondaryText)
                            }
                            if let pill = state.pill, let tone = state.tone {
                                Pill(text: pill, tone: tone)
                            }
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                        }
                        .cardMenu(id: item.itemId)
                    }
                } header: {
                    SectionTitle(release.showsProgress ? "Progress" : "Items", count: release.items.count)
                } footer: {
                    if release.showsProgress {
                        Text(release.readinessLine).foregroundStyle(Color.secondaryText)
                    }
                }
                if !release.tests.isEmpty {
                    Section {
                        ForEach(release.tests) { test in
                            LabeledContent(test.machine, value: test.result.capitalizedFirst)
                        }
                    } header: {
                        SectionTitle("Tests")
                    }
                }
            } else if let failure {
                Text(failure).foregroundStyle(Color.errorText)
            } else {
                ProgressView()
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(release?.version ?? "Release")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { release = try await store.release(releaseId) } catch { failure = error.localizedDescription }
        }
    }
}

// MARK: Meetings

struct MeetingsPane: View {
    @Environment(Fleet.self) private var fleet
    let home: (computer: Computer, projectId: String)?
    @State private var dashboard: Dashboard?
    @State private var failure: String?

    var body: some View {
        List {
            if let dashboard {
                if dashboard.meetings.isEmpty { EmptyNote(text: "No meetings set up", systemImage: "person.3") }
                ForEach(dashboard.meetings) { meeting in
                    Section {
                        ItemRow(title: meeting.name, subtitle: line(meeting)) {
                            IconTile(systemImage: "person.3", tone: meeting.collecting ? .working : nil)
                        }
                        if let summary = meeting.lastSummary {
                            Text(fleet.linkedText(summary)).font(.callout)
                                .cardMenu(for: summary)
                        }
                    }
                }
            } else if let failure {
                Text(failure).foregroundStyle(Color.errorText)
            } else {
                ProgressView()
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
        .task { await load() }
    }

    private func line(_ meeting: Dashboard.Meeting) -> String {
        var parts: [String] = []
        if meeting.collecting { parts.append("Collecting now") }
        if let next = meeting.nextAt { parts.append("Next \(next.formatted(date: .abbreviated, time: .shortened))") }
        if let held = meeting.lastHeldAt { parts.append("Last held \(held.relative)") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        guard let home else { return }
        do { dashboard = try await home.computer.store.dashboard(projectId: home.projectId) } catch { failure = error.localizedDescription }
    }
}

extension String {
    /// "ship" → "Ship".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst().replacingOccurrences(of: "_", with: " ") }
}
