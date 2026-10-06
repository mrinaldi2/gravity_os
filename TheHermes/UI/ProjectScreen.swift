import SwiftUI

// UX-024: a project opens on its Overview; Board and Team follow, then
// Releases and Meetings. Board, releases and meetings come from the board's
// home; bots from the computer that answered (H-128 R2.1).

struct ProjectScreen: View {
    @Environment(Fleet.self) private var fleet
    @Environment(AppStore.self) private var store
    let projectId: String
    @State private var segment = Segment.overview
    @State private var showingArtifacts = false

    enum Segment: String, CaseIterable {
        case overview = "Overview", board = "Board", team = "Team", releases = "Releases", meetings = "Meet."
    }

    private var project: Project? { store.projects.first { $0.id == projectId } }

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
        VStack(spacing: 0) {
            Picker("Section", selection: $segment) {
                ForEach(Segment.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            Group {
                switch segment {
                case .overview: OverviewPane(projectId: projectId, card: card, home: home)
                case .board: BoardPane(home: home)
                case .team: TeamPane(projectId: projectId)
                case .releases: ReleasesPane(home: home)
                case .meetings: MeetingsPane(home: home)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(project?.name ?? card?.row.name ?? "Project")
        .navigationBarTitleDisplayMode(.large)
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

// MARK: Overview

struct OverviewPane: View {
    @Environment(Fleet.self) private var fleet
    let projectId: String
    let card: HomeCard?
    let home: (computer: Computer, projectId: String)?
    @State private var dashboard: Dashboard?
    @State private var failure: String?

    private var needs: [HomeAttentionRow] { card.map { fleet.home.attention[$0.id] ?? [] } ?? [] }

    var body: some View {
        List {
            if let card, card.row.attention.count > 0 {
                Section {
                    if needs.isEmpty {
                        Text(AttentionWords.summary(card.row.attention, limit: 5)).foregroundStyle(Color.secondaryText)
                    }
                    ForEach(needs, id: \.id) { row in
                        NavigationLink(value: fleet.needsDestination(row, answeredBy: card.computerId)) { NeedsRow(row: row) }
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
        .task { await load() }
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
    @State private var board: BoardSnapshot?
    @State private var failure: String?
    @State private var column = ""

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
    @Environment(AppStore.self) private var store
    let itemId: String
    @State private var detail: BoardItemDetail?
    @State private var draft = ""
    @State private var sending = false
    @State private var failure: String?

    var body: some View {
        List {
            if let item = detail?.item {
                Section {
                    Text(item.title).font(.headline)
                    if !item.description_p.isEmpty {
                        Text(LocalizedStringKey(item.description_p)).font(.callout)
                    }
                } header: {
                    SectionTitle(item.id)
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
                    if detail?.comments.isEmpty ?? true { EmptyNote(text: "No comments yet", systemImage: "text.bubble") }
                    ForEach(detail?.comments ?? [], id: \.id) { comment in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(author(comment.author)).font(.caption.weight(.semibold))
                            Text(comment.body).font(.callout)
                            if comment.hasAt { Text(comment.at.date.relative).font(.caption2).foregroundStyle(Color.secondaryText) }
                        }
                    }
                    if store.canControl {
                        HStack {
                            TextField("Comment", text: $draft, prompt: .placeholder("Comment on \(itemId)"), axis: .vertical)
                            Button("Send") { send() }.disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || sending)
                        }
                    }
                } header: {
                    SectionTitle("Activity")
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
        .task { await load() }
        .errorAlert("Couldn’t post the comment.", $failure)
    }

    private func author(_ actor: String) -> String {
        if actor == "user" || actor == "owner" || actor.hasPrefix("device:") { return "You" }
        let id = actor.hasPrefix("bot:") ? String(actor.dropFirst(4)) : actor
        return store.bot(id)?.name ?? id
    }

    private func load() async {
        do { detail = try await store.item(itemId) } catch { failure = error.localizedDescription }
    }

    private func send() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        sending = true
        Task {
            do {
                try await store.comment(on: itemId, body)
                draft = ""
                await load()
            } catch {
                failure = error.localizedDescription
            }
            sending = false
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
                    BotRow(bot: bot)
                }
            }
        }
        .listStyle(.insetGrouped)
    }
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
    @Environment(AppStore.self) private var store
    let releaseId: String
    @State private var release: Release?
    @State private var failure: String?

    var body: some View {
        List {
            if let release {
                Section {
                    let (words, tone) = release.statusWords
                    Pill(text: words, tone: tone)
                    if let changelog = release.changelog, !changelog.isEmpty {
                        Text(LocalizedStringKey(changelog)).font(.callout)
                    }
                    Text(release.canRule
                         ? "Ruling on a release from the phone comes with the release review. Approve, hold or reject it on the desktop for now."
                         : "Rule on it on \(release.ruleOn ?? "the board's home computer"), in The Hermes app.")
                        .font(.footnote).foregroundStyle(Color.secondaryText)
                }
                Section {
                    ForEach(release.items) { item in
                        ItemRow(title: item.itemId, subtitle: item.note) {
                            IconTile(systemImage: "square.text.square")
                        } trailing: {
                            Pill(text: item.verdict.capitalizedFirst, tone: item.verdict == "ship" ? .ready : item.verdict == "pending" ? .quiet : .needsYou)
                        }
                    }
                } header: {
                    SectionTitle("Items", count: release.items.count)
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
                            Text(summary).font(.callout)
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
