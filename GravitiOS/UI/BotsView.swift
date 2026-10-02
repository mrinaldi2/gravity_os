import SwiftUI

struct BotsView: View {
    @Environment(AppStore.self) private var store
    @State private var path = NavigationPath()
    @State private var creating: Creating?
    @State private var linking: ProjectRef?
    @State private var editingRepo: ProjectRef?
    @State private var showingNetwork = false

    struct ProjectRef: Identifiable {
        let id: String
    }

    /// What the create sheet is making.
    enum Creating: Identifiable {
        case project
        case bot(projectId: String?)

        var id: String {
            switch self {
            case .project: "project"
            case .bot(let projectId): "bot-\(projectId ?? "")"
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(store.sortedProjects) { project in
                    Section {
                        let bots = store.bots(in: project)
                        if bots.isEmpty {
                            Text("No bots").foregroundStyle(.secondary)
                        }
                        ForEach(bots) { bot in
                            NavigationLink(value: bot.id) { BotRow(bot: bot) }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Text(project.name)
                            ForEach(project.links) { link in
                                Label(link.peerName, systemImage: "link")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background((link.online ? Color.green : Color.gray).opacity(0.15), in: Capsule())
                                    .foregroundStyle(link.online ? .green : .secondary)
                                    .textCase(nil)
                            }
                            Spacer()
                            // Reading is open to every device; changing things needs control.
                            if store.canControl || store.hasWorkers || store.hasConversations {
                                Menu {
                                    if store.canControl {
                                        Button { creating = .bot(projectId: project.id) } label: {
                                            Label("New bot", systemImage: "person.badge.plus")
                                        }
                                    }
                                    if store.hasWorkers {
                                        Button { path.append(WorkersLink(projectId: project.id)) } label: {
                                            Label("Workers", systemImage: "person.3.sequence")
                                        }
                                        Button { editingRepo = ProjectRef(id: project.id) } label: {
                                            Label(project.repo.map { "Shared repository · \($0.branch)" } ?? "Shared repository",
                                                  systemImage: "arrow.triangle.branch")
                                        }
                                    }
                                    if store.hasConversations {
                                        Button { path.append(ConversationsLink(projectId: project.id)) } label: {
                                            Label("Conversations", systemImage: "bubble.left.and.bubble.right")
                                        }
                                    }
                                    if store.canControl {
                                        Button { linking = ProjectRef(id: project.id) } label: {
                                            Label(project.links.isEmpty ? "Link with another computer" : "Linked computers",
                                                  systemImage: "link")
                                        }
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                                .accessibilityLabel("\(project.name) actions")
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if store.projects.isEmpty {
                    ContentUnavailableView(
                        store.status == .connected ? "No projects yet" : store.status.label,
                        systemImage: "person.2.slash",
                        description: Text(emptyDetail))
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { ConnectionBanner() }
            .refreshable { await store.refresh() }
            .navigationTitle("Bots")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { SettingsButton() }
                ToolbarItem(placement: .topBarLeading) { ComputerSwitcher() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingNetwork = true } label: { Image(systemName: "point.3.connected.trianglepath.dotted") }
                        .accessibilityLabel("Network")
                }
                if store.canControl, store.status == .connected {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button { creating = .bot(projectId: nil) } label: { Label("New bot", systemImage: "person.badge.plus") }
                                .disabled(store.projects.isEmpty)
                            Button { creating = .project } label: { Label("New project", systemImage: "folder.badge.plus") }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Create")
                    }
                }
            }
            .sheet(item: $creating) { item in
                switch item {
                case .project:
                    NewProjectSheet { project, addBot in
                        creating = nil
                        if addBot {
                            // Let the first sheet go before the next one comes up.
                            Task {
                                try? await Task.sleep(for: .milliseconds(450))
                                creating = .bot(projectId: project.id)
                            }
                        }
                    }
                case .bot(let projectId):
                    NewBotSheet(projectId: projectId) { bot in
                        creating = nil
                        path.append(bot.id)
                    }
                }
            }
            .sheet(item: $linking) { LinkProjectSheet(projectId: $0.id) }
            .sheet(item: $editingRepo) { RepoSheet(projectId: $0.id) }
            .sheet(isPresented: $showingNetwork) { NetworkView() }
            .navigationDestination(for: String.self) { BotDetailView(botId: $0) }
            .navigationDestination(for: ConversationsLink.self) { ConversationsView(projectId: $0.projectId) }
            .navigationDestination(for: WorkersLink.self) { WorkersView(projectId: $0.projectId) }
            #if DEBUG
            // Screenshots of the demo: -openConversations opens the first project's,
            // -openWorkers the Workers of the one with a repository, -openBot <name> that bot.
            .task(id: store.bots.count) {
                guard path.isEmpty else { return }
                if let name = UserDefaults.standard.string(forKey: "openBot"),
                   let bot = store.bots.first(where: { $0.name == name }) {
                    path.append(bot.id)
                } else if UserDefaults.standard.bool(forKey: "openWorkers"),
                          let project = store.sortedProjects.first(where: { $0.repo != nil }) ?? store.sortedProjects.first {
                    path.append(WorkersLink(projectId: project.id))
                } else if UserDefaults.standard.bool(forKey: "openConversations"),
                          let first = store.sortedProjects.first {
                    path.append(ConversationsLink(projectId: first.id))
                }
            }
            #endif
            .navigationDestination(for: TurnLink.self) { TurnDetailView(botId: $0.botId, turnId: $0.turnId) }
        }
    }

    private var emptyDetail: String {
        switch store.status {
        case .connected: "Create a project and bots in Gravity on \(store.computerName)."
        case .disconnected(let reason): reason
        case .authFailed(let reason), .versionMismatch(let reason): reason
        default: ""
        }
    }
}

private struct BotRow: View {
    @Environment(AppStore.self) private var store
    @Environment(LensStore.self) private var lens
    let bot: Bot

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(avatar: bot.avatar, name: bot.name)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(bot.name).font(.headline)
                    if bot.temporary { WorkerTag() }
                    if store.isUnread(bot) {
                        Circle().fill(.tint).frame(width: 8, height: 8)
                    }
                    Spacer()
                    if let machine = bot.peerName {
                        Label(machine, systemImage: "link").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if bot.engine == .codex {
                        Text("Codex").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    StateBadge(state: bot.state)
                }
                if let turn = lens.latest[bot.id], turn.open, bot.state == .working, !turn.current.isEmpty {
                    Label(turn.current, systemImage: "play.fill")
                        .font(.subheadline)
                        .foregroundStyle(.tint)
                        .lineLimit(2)
                } else if let detail = store.approvals[bot.id] {
                    Text(detail).font(.subheadline).foregroundStyle(.orange).lineLimit(2)
                } else if let outcome = lens.latest[bot.id]?.outcome, outcome.kind != "none" {
                    Text(outcome.kind == "message" ? "To \(outcome.to): \(outcome.text)" : outcome.text)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if let activity = store.activity[bot.id] {
                    Text(activity.from.isEmpty ? activity.text : "\(activity.from): \(activity.text)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if !bot.description.isEmpty {
                    Text(bot.description).font(.subheadline).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
