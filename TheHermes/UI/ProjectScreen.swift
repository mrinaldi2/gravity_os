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
        // iPad keyboard (UX-023 §2.7): ⌘1–5 pick a segment.
        .background {
            ForEach(Array(Segment.allCases.enumerated()), id: \.offset) { index, choice in
                Button(choice.rawValue) { segment = choice }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
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
                            .dismissible(row)
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
            // "Doing 0 of 1" (UX-038), not "0/1".
            let count = column.wipLimit.map { "\(column.count) of \($0)" } ?? "\(column.count)"
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
    @State private var replying: CommentRow?
    @State private var failure: String?
    @FocusState private var composing: Bool

    /// Who an owner comment reaches (H-201): the card's assignee and the project's lead.
    private var told: [String] {
        var names: [String] = []
        if let assignee = detail?.item, assignee.hasAssignee, let name = store.bot(assignee.assignee)?.name { names.append(name) }
        let projectId = fleet.cards.home(for: itemId)?.projectId
        if let lead = store.projects.first(where: { $0.id == projectId })?.leadBotId,
           let name = store.bot(lead)?.name, !names.contains(name) {
            names.append(name)
        }
        return names
    }

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
                        LinkedText(markdown: item.description_p)
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
        .sheet(item: $replying) { row in
            ReplySheet(to: CommentWords.author(row.author) { store.bot($0)?.name }, quote: row.body ?? "") { body in
                replying = nil
                post(body, replyTo: row.id)
            }
        }
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
                    LinkedText(markdown: body)
                } else {
                    Text("A comment. Its text shows once the Hermes service on \(store.computerName.isEmpty ? "your computer" : store.computerName) is updated.")
                        .foregroundStyle(Color.secondaryText)
                }
            }
            .font(.callout)
            .textSelection(.enabled)
            if row.status == .sent {
                // Who the comment reached (UX-041): the assignee and the lead.
                Text(CommentWords.posted(told: told)).font(.caption).foregroundStyle(Color.successText)
            }
            if case .failed(let message) = row.status {
                HStack(spacing: 12) {
                    Text(CommentWords.couldntPost(message)).font(.caption).foregroundStyle(Color.errorText)
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
                // A sheet with the comment and a focused field (H-210): the inline
                // composer sits at the end of the list, often off screen.
                Button("Reply") { replying = row }
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
            // The line under the comment says it: "✓ Posted. … are told."
            EmptyView()
        case .failed:
            Label("Couldn’t post", systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(Color.errorText)
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
        draft = ""
        let to = replyTo?.status == .onBoard ? replyTo?.id : nil
        replyTo = nil
        post(body, replyTo: to)
    }

    private func post(_ body: String, replyTo: String?) {
        let comment = PendingComment(body: body, replyTo: replyTo)
        pending.append(comment)
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
                // The bot's question on this card closes with your comment: Needs you follows.
                await fleet.home.refreshAll(fleet.computers, force: true)
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

/// "Reply to Desktop Dev": the comment you answer, and a field ready to type (H-210).
private struct ReplySheet: View {
    @Environment(\.dismiss) private var dismiss
    let to: String
    let quote: String
    let send: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                if !quote.isEmpty {
                    Section(to) {
                        Text(quote).font(.callout).foregroundStyle(Color.secondaryText).lineLimit(6)
                    }
                }
                Section {
                    TextField("Your reply", text: $text, prompt: .placeholder("Your reply"), axis: .vertical)
                        .lineLimit(3...10)
                        .focused($focused)
                }
            }
            .navigationTitle(CommentWords.replyTitle(to))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
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
    /// The owner's choices before approving: items left out, and where they go.
    @State private var leftOut: [String: LeftOut] = [:]
    @State private var leavingOut: String?
    @State private var holding = false
    @State private var rejecting = false
    @State private var busy = false
    /// Approvals wait out their Undo app-wide (UX-040): this screen shows the bar too.
    private var pending: RulingQueue.Pending? {
        fleet.rulings.pending.flatMap { $0.releaseId == releaseId ? $0 : nil }
    }

    /// The computer this release was read from.
    private var computerId: String { fleet.computers.first { $0.store === store }?.id ?? "" }

    /// The phone rules on a package waiting for the owner, when it may (H-160 AC4).
    private var reviewing: Bool {
        guard let release else { return false }
        return release.status == "awaiting_owner" && release.canRule && store.canApprove
    }

    var body: some View {
        List {
            if let release {
                Section {
                    let (words, tone) = release.statusWords
                    Pill(text: words, tone: tone)
                    if let by = release.createdBy.flatMap({ store.bot($0)?.name }) ?? release.createdBy {
                        Text([by, release.createdAt.map { $0.formatted(date: .omitted, time: .shortened) }].compactMap { $0 }.joined(separator: " · "))
                            .font(.footnote).foregroundStyle(Color.secondaryText)
                    }
                    if let changelog = release.changelog, !changelog.isEmpty {
                        LinkedText(markdown: changelog)
                    }
                    if release.status == "awaiting_owner", let why = ReleaseReview.cannotRule(release, canApprove: store.canApprove) {
                        Text(why).font(.footnote).foregroundStyle(Color.secondaryText)
                    }
                }
                if !release.tests.isEmpty {
                    Section {
                        ForEach(release.tests) { test in
                            LabeledContent(test.machine, value: test.result == "pass" ? "✓ Passed" : "✗ \(test.result.capitalizedFirst)")
                        }
                    } header: {
                        SectionTitle("Tests")
                    }
                }
                Section {
                    ForEach(release.items) { item in itemRow(release, item) }
                } header: {
                    SectionTitle(release.showsProgress ? "Progress" : "Items", count: release.items.count)
                } footer: {
                    if release.showsProgress {
                        Text(release.readinessLine).foregroundStyle(Color.secondaryText)
                    } else if reviewing, let line = ReleaseReview.leftOutLine(leftOut.count) {
                        Text(line).foregroundStyle(Color.secondaryText)
                    }
                }
                if reviewing { actions(release) }
                if let failure {
                    Text(failure).font(.footnote).foregroundStyle(Color.errorText)
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
        .task { await load() }
        // An approval for this package ended (here or elsewhere): show it as it is now.
        .task(id: fleet.rulings.outcome?.id) {
            guard let outcome = fleet.rulings.outcome, outcome.releaseId == releaseId else { return }
            await load()
            if outcome.ok || outcome.changed { leftOut = [:] }
        }
        .sheet(item: Binding(get: { leavingOut.map(ItemRef.init) }, set: { leavingOut = $0?.id })) { ref in
            LeaveOutSheet(itemId: ref.id, title: release?.plan.first { $0.itemId == ref.id }?.title ?? "") { out in
                leftOut[ref.id] = out
                leavingOut = nil
            }
        }
        .sheet(isPresented: $holding) {
            if let release {
                HoldReleaseSheet(version: release.version) { note, remind in
                    holding = false
                    act { self.release = try await store.holdRelease(release, note: note, remindAt: remind) }
                }
            }
        }
        .sheet(isPresented: $rejecting) {
            if let release {
                RejectReleaseSheet(release: release) { reason, returns in
                    rejecting = false
                    act {
                        try await OwnerAuth.confirm("Reject \(release.version)?", action: .reject, computer: store.computerName)
                        self.release = try await store.ruleRelease(release,
                                                                   verdicts: ReleaseReview.rejection(release, reason: reason, returns: returns))
                    }
                }
            }
        }
    }

    @ViewBuilder private func itemRow(_ release: Release, _ item: Release.Item) -> some View {
        let state = release.state(of: item) { store.bot($0)?.name }
        let out = leftOut[item.itemId]
        HStack(alignment: .top, spacing: 8) {
            // The row is the card: tap opens it, long-press previews it (H-204).
            NavigationLink(value: NeedsDestination.item(computerId: fleet.cards.home(for: item.itemId)?.computerId ?? computerId,
                                                        itemId: item.itemId)) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.title).font(.subheadline.weight(.medium)).lineLimit(3)
                    if let meta = state.meta {
                        Text(meta).font(.caption).foregroundStyle(Color.secondaryText)
                    }
                    if let out {
                        Pill(text: "⤼ " + ReleaseReview.outWords(out), tone: .quiet)
                    } else if let pill = state.pill, let tone = state.tone {
                        Pill(text: pill, tone: tone)
                    }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                .contentShape(Rectangle())
                .hoverEffect(.highlight)
            }
            .cardMenu(id: item.itemId)
            if reviewing {
                Button(out == nil ? "Leave out" : "Include") {
                    if out == nil { leavingOut = item.itemId } else { leftOut[item.itemId] = nil }
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.bordered)
                .accessibilityLabel(out == nil ? "Leave out \(item.itemId)" : "Include \(item.itemId)")
            }
        }
    }

    @ViewBuilder private func actions(_ release: Release) -> some View {
        Section {
            if let pending {
                HStack {
                    Text(pending.label).font(.subheadline)
                    Spacer()
                    Button("Undo") { fleet.rulings.undo() }.fontWeight(.semibold)
                }
            } else {
                Button {
                    approve(release)
                } label: {
                    Label(ReleaseReview.approveButton(release, leftOut: leftOut.count), systemImage: "faceid")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || leftOut.count == release.items.count)
                Button("Hold") { holding = true }.disabled(busy)
                Button("Reject…", role: .destructive) { rejecting = true }.disabled(busy)
            }
        } footer: {
            Text(ReleaseReview.approveBody(release, leftOut: leftOut.count)).foregroundStyle(Color.secondaryText)
        }
    }

    /// Face ID, then 5 s to Undo (app-wide), then `release_rule`.
    private func approve(_ release: Release) {
        let verdicts = ReleaseReview.approval(release, leftOut: leftOut)
        let count = leftOut.count
        let store = store
        act {
            try await OwnerAuth.confirm(ReleaseReview.approveQuestion(release, leftOut: count),
                                        action: .approve, computer: store.computerName)
            fleet.rulings.approve(release, leftOut: count) {
                try await store.ruleRelease(release, verdicts: verdicts)
            }
        }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            do {
                try await work()
                failure = nil
            } catch {
                // CE: the package changed under the owner: reload it and say so.
                if let release, RulingWords.isConflict(error) {
                    await load()
                    leftOut = [:]
                    failure = RulingWords.changed(release)
                } else {
                    failure = error.localizedDescription
                }
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            busy = false
        }
    }

    private func load() async {
        do { release = try await store.release(releaseId) } catch { failure = error.localizedDescription }
    }
}

private struct ItemRef: Identifiable { let id: String }

/// "Leave out H-117?": where it goes, and why (desktop LeaveOutDialog).
private struct LeaveOutSheet: View {
    @Environment(\.dismiss) private var dismiss
    let itemId: String
    let title: String
    let done: (LeftOut) -> Void
    @State private var verdict = LeftOut.Verdict.hold
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                if !title.isEmpty { Text(title) }
                Section("It goes") {
                    Picker("It goes", selection: $verdict) {
                        Text("Hold: it waits for the next release").tag(LeftOut.Verdict.hold)
                        Text("Rework: back to Doing, with a note").tag(LeftOut.Verdict.rework)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section(verdict == .rework ? "What needs rework" : "Note (optional)") {
                    TextField(verdict == .rework ? "What needs rework" : "Note (optional)", text: $note,
                              prompt: .placeholder(verdict == .rework ? "What needs rework" : "Note (optional)"), axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .navigationTitle("Leave out \(itemId)?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Leave out") { done(LeftOut(verdict: verdict, note: note.trimmingCharacters(in: .whitespacesAndNewlines))) }
                        .disabled(verdict == .rework && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// "Hold 0.17.0?": a note and when to be reminded (desktop HoldDialog).
private struct HoldReleaseSheet: View {
    @Environment(\.dismiss) private var dismiss
    let version: String
    let done: (String, Date?) -> Void
    @State private var note = ""
    @State private var remind = ReleaseReview.Remind.tomorrow

    var body: some View {
        NavigationStack {
            Form {
                Section("Note (optional)") {
                    TextField("Note (optional)", text: $note, prompt: .placeholder("Note (optional)"), axis: .vertical).lineLimit(2...5)
                }
                Section("Remind me") {
                    Picker("Remind me", selection: $remind) {
                        ForEach(ReleaseReview.Remind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .navigationTitle("Hold \(version)?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hold") { done(note.trimmingCharacters(in: .whitespacesAndNewlines), remind.date()) }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// "Reject 0.17.0?": a reason for every item, and where each goes (desktop RejectDialog).
private struct RejectReleaseSheet: View {
    @Environment(\.dismiss) private var dismiss
    let release: Release
    let done: (String, [String: LeftOut.Verdict]) -> Void
    @State private var reason = ""
    @State private var returns: [String: LeftOut.Verdict] = [:]

    var body: some View {
        NavigationStack {
            Form {
                Section("Reason (sent to DevOps and copied to every item)") {
                    TextField("Reason", text: $reason, prompt: .placeholder("Reason"), axis: .vertical).lineLimit(2...5)
                }
                Section {
                    ForEach(release.items) { item in
                        Picker(release.plan.first { $0.itemId == item.itemId }.map { "\(item.itemId) · \($0.title)" } ?? item.itemId,
                               selection: Binding(get: { returns[item.itemId] ?? .rework }, set: { returns[item.itemId] = $0 })) {
                            Text("Back to Doing").tag(LeftOut.Verdict.rework)
                            Text("Back to Ready").tag(LeftOut.Verdict.hold)
                        }
                        .accessibilityLabel("Where \(item.itemId) goes")
                    }
                } header: {
                    Text("Where each item goes")
                } footer: {
                    if let hint = ReleaseReview.rejectHint(returns.merging(Dictionary(uniqueKeysWithValues: release.items.map { ($0.itemId, LeftOut.Verdict.rework) })) { mine, _ in mine },
                                                           items: release.items.count) {
                        Text(hint).foregroundStyle(Color.secondaryText)
                    }
                }
            }
            .navigationTitle("Reject \(release.version)?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Reject", role: .destructive) { done(reason.trimmingCharacters(in: .whitespacesAndNewlines), returns) }
                        .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
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
                            LinkedText(markdown: summary)
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
