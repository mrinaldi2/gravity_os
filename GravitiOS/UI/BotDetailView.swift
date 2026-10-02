import SwiftUI

struct BotDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(LensStore.self) private var lens
    @Environment(\.scenePhase) private var scenePhase
    let botId: String
    @State private var choice: Pane?
    @State private var searching = false
    @State private var confirming: SessionAction?
    @State private var notice: String?
    @State private var failure: String?

    enum Pane: String, CaseIterable {
        case chat = "Chat"
        case activity = "Activity"
        case terminal = "Terminal"
        case browser = "Browser"
        case messages = "Messages"
        case tasks = "Tasks"
        case commands = "Commands"
        case files = "Files"
        case memory = "Memory"
        case info = "Info"
    }

    private var bot: Bot? { store.bot(botId) }

    /// A daemon that serves chat gets Gravity's chat pane and the panes after
    /// it, each as the daemon offers it; an older one keeps the Gravity Lens
    /// activity and the message thread.
    private var panes: [Pane] {
        guard let bot else { return [.info] }
        guard store.hasChat else {
            return [.activity, .messages, .info] + (store.hasTerminal(bot) ? [.terminal] : [])
        }
        var panes: [Pane] = [.chat]
        if store.hasTerminal(bot) { panes.append(.terminal) }
        if store.hasBrowser(bot) { panes.append(.browser) }
        panes.append(.tasks)
        if store.hasCommands { panes.append(.commands) }
        panes += [.files, .memory, .info]
        return panes
    }

    private var pane: Pane {
        if let choice, panes.contains(choice) { return choice }
        return panes[0]
    }

    /// The bot's browser is open: its tab shows a red dot, as on the desktop.
    private var browserOpen: Bool { store.browserTabs?.botId == botId && store.browserTabs?.open == true }

    var body: some View {
        VStack(spacing: 0) {
            PaneStrip(panes: panes, selection: Binding(get: { pane }, set: { choice = $0 }), browserOpen: browserOpen)

            // Its tools waiting on the owner, answered right here.
            if store.hasPermissions, !store.permissions(for: botId).isEmpty {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(store.permissions(for: botId)) { PermissionCard(request: $0) }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 340)
                .fixedSize(horizontal: false, vertical: true)
            } else if let detail = store.approvals[botId] {
                Label(detail, systemImage: "hand.raised.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            if let notice {
                Label(notice, systemImage: "arrow.clockwise")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(6))
                        if self.notice == notice { self.notice = nil }
                    }
            }

            switch pane {
            case .chat: BotChatPane(botId: botId, searching: $searching)
            case .tasks: BotTasksPane(botId: botId)
            case .browser: BrowserPane(botId: botId)
            case .commands: CommandsPane(botId: botId)
            case .files: BotFilesPane(botId: botId)
            case .memory: MemoryPane(botId: botId)
            case .activity: BotActivityView(botId: botId)
            case .terminal: TerminalScreen(botId: botId)
            case .messages: ChatView(botId: botId)
            case .info: BotInfoView(botId: botId)
            }
        }
        .navigationTitle(bot?.name ?? "Bot")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let bot { StateBadge(state: bot.state) }
            }
            if pane == .chat {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { searching.toggle() } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel("Search this chat")
                }
            }
            if store.canRestart {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { confirming = .restart } label: { Label("Restart", systemImage: "arrow.clockwise") }
                        Button { confirming = .clear } label: { Label("Clear chat", systemImage: "eraser") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Session")
                    .disabled(store.status != .connected)
                }
            }
        }
        .confirmationDialog(confirming?.title(bot?.name ?? "the bot") ?? "", isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible
        ) {
            if let action = confirming {
                Button(action.confirm, role: action == .clear ? .destructive : nil) { run(action) }
            }
        } message: {
            Text(confirming?.body(bot?.name ?? "The bot") ?? "")
        }
        .errorAlert($failure)
        .toolbar(.hidden, for: .tabBar)
        // The browser is watched while the bot is on screen, whatever pane is
        // open, so the Browser pane is live the moment it is chosen.
        .onAppear {
            store.markSeen(botId)
            store.botOnScreen = botId
            watchBrowser()
            #if DEBUG
            // Screenshots of the demo: -openPane Commands opens that pane.
            if choice == nil, let name = UserDefaults.standard.string(forKey: "openPane") {
                choice = Pane(rawValue: name)
            }
            #endif
        }
        .onDisappear {
            store.markSeen(botId)
            if store.botOnScreen == botId { store.botOnScreen = nil }
            if store.watchedBrowser?.botId == botId { store.unwatchBrowser() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { watchBrowser() } else if store.watchedBrowser?.botId == botId { store.unwatchBrowser() }
        }
    }

    private func watchBrowser() {
        guard let bot, store.hasBrowser(bot), store.watchedBrowser?.botId != botId else { return }
        store.watchBrowser(botId)
    }

    private func run(_ action: SessionAction) {
        let name = bot?.name ?? "The bot"
        Task {
            do {
                switch action {
                case .restart:
                    try await store.restartBot(botId)
                case .clear:
                    try await store.clearBotSession(botId)
                    // The new conversation starts empty.
                    await lens.resetChat(botId)
                }
                notice = action.done(name)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// Restart and Clear chat, with the words Gravity's desktop uses.
enum SessionAction {
    case restart, clear

    func title(_ name: String) -> String {
        switch self {
        case .restart: "Restart \(name)?"
        case .clear: "Clear \(name)'s conversation?"
        }
    }

    func body(_ name: String) -> String {
        switch self {
        case .restart:
            "Its session restarts and picks its conversation back up. If it was in the middle of something, it is told what it was doing and which tasks are open, so it carries on. Its files, memory and tasks are kept."
        case .clear:
            "It restarts with a fresh conversation, without this one's history, which leaves the chat. Its files, its memory (FACTS.md) and its tasks are kept, and it is told what it was working on so it can carry on."
        }
    }

    var confirm: String {
        switch self {
        case .restart: "Restart"
        case .clear: "Clear conversation"
        }
    }

    func done(_ name: String) -> String {
        switch self {
        case .restart: "\(name) is restarting and will pick up where it left off."
        case .clear: "\(name) is starting a fresh conversation and will carry on its work."
        }
    }
}

/// The bot's panes, one row that scrolls when they do not fit.
private struct PaneStrip: View {
    let panes: [BotDetailView.Pane]
    @Binding var selection: BotDetailView.Pane
    let browserOpen: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(panes, id: \.self) { pane in
                        Button { selection = pane } label: {
                            HStack(spacing: 4) {
                                Text(pane.rawValue)
                                if pane == .browser, browserOpen {
                                    Circle().fill(.red).frame(width: 6, height: 6)
                                }
                            }
                            .font(.subheadline.weight(selection == pane ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .foregroundStyle(selection == pane ? Color(.systemBackground) : .primary)
                            .background(selection == pane ? Color.primary : Color(.tertiarySystemFill), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .id(pane)
                        .accessibilityAddTraits(selection == pane ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: selection) { _, pane in withAnimation { proxy.scrollTo(pane, anchor: .center) } }
        }
    }
}

private struct BotInfoView: View {
    @Environment(AppStore.self) private var store
    let botId: String

    var body: some View {
        List {
            if let bot = store.bot(botId) {
                Section {
                    HStack(spacing: 12) {
                        AvatarView(avatar: bot.avatar, name: bot.name, size: 52)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(bot.name).font(.title3.weight(.semibold))
                                if bot.temporary { WorkerTag() }
                            }
                            Text(store.projectName(bot.projectId)).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("State") { StateBadge(state: bot.state) }
                    if !bot.stateReason.isEmpty {
                        LabeledContent("Reason", value: bot.stateReason)
                    }
                    if bot.temporary {
                        Label("Temporary worker spawned by \(bot.createdByBotId.flatMap(store.bot)?.name ?? "a bot"); removed when its task closes",
                              systemImage: "hammer")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if let creator = bot.createdByBotId.flatMap(store.bot) {
                        LabeledContent("Created by", value: creator.name)
                    }
                }
                if !bot.description.isEmpty {
                    Section("Description") { Text(bot.description) }
                }
                if !bot.instructions.isEmpty {
                    Section("Instructions") {
                        Text(bot.instructions).font(.callout).textSelection(.enabled)
                    }
                }
                if store.capabilities.contains("bot_browser"), !bot.isLinked {
                    ChromeAccessSection(bot: bot)
                }
                RoutinesSection(botId: botId)
                Section("Workspace") {
                    Text(bot.workspacePath).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
    }
}

private struct RoutinesSection: View {
    @Environment(AppStore.self) private var store
    let botId: String
    @State private var routines: [Routine] = []
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        Section("Routines") {
          if loaded, routines.isEmpty {
            Text("No routines. Ask the bot to schedule one, or add it in Gravity on that computer.")
                .font(.footnote).foregroundStyle(.secondary)
          }
          ForEach(routines) { routine in
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: Binding(
                    get: { routine.enabled },
                    set: { enabled in run { try await setEnabled(routine, enabled) } })
                ) {
                    Text(routine.name).font(.headline)
                }
                .disabled(!store.canControl)
                Text(routine.triggerSummary).font(.subheadline).foregroundStyle(.secondary)
                if let next = routine.nextRunAt, routine.enabled {
                    Text("Next run \(next.relative)").font(.caption).foregroundStyle(.secondary)
                }
                Text(routine.prompt).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                if store.canControl {
                    Button("Run now") {
                        run { _ = try await store.client.request("run_routine_now", ["routine_id": routine.id]) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 4)
          }
        }
        .task(id: store.status) { await load() }
        .errorAlert($error)
    }

    private func load() async {
        guard let reply = try? await store.client.request("list_routines", ["bot_id": botId]) else { return }
        routines = reply.list("routines").map(Routine.init)
        loaded = true
    }

    private func setEnabled(_ routine: Routine, _ enabled: Bool) async throws {
        _ = try await store.client.request("set_routine_enabled", ["routine_id": routine.id, "enabled": enabled])
        await load()
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
}

/// Whether the bot may also drive the owner's own Chrome. Off by default:
/// every bot has a browser of its own, and this is for the task that needs
/// the owner's logged-in sessions. Changing it restarts the bot's session.
private struct ChromeAccessSection: View {
    @Environment(AppStore.self) private var store
    let bot: Bot
    @State private var saving = false
    @State private var note: String?
    @State private var failure: String?

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { bot.userChrome }, set: { save($0) })) {
                Text("Can use your Chrome")
            }
            .disabled(!store.canControl || store.status != .connected || saving)
            // On the row, not the Section: a List applies a section's modifiers to each row.
            .errorAlert($failure)
            if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("Browser")
        } footer: {
            Text("\(bot.name) always has a browser of its own. Allow this only for tasks that need your logged-in sessions; its tabs then open in your Chrome. Restarts the bot.")
        }
    }

    private func save(_ enabled: Bool) {
        saving = true
        Task {
            do {
                try await store.setUserChrome(botId: bot.id, enabled: enabled)
                note = "\(bot.name) is restarting \(enabled ? "with" : "without") access to your Chrome."
            } catch {
                failure = error.localizedDescription
            }
            saving = false
        }
    }
}
