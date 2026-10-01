import SwiftUI

struct BotDetailView: View {
    @Environment(AppStore.self) private var store
    let botId: String
    @State private var pane = Pane.activity

    enum Pane: String, CaseIterable {
        case activity = "Activity"
        case terminal = "Terminal"
        case messages = "Messages"
        case info = "Info"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $pane) {
                ForEach(Pane.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if let detail = store.approvals[botId] {
                Label(detail, systemImage: "hand.raised.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            switch pane {
            case .activity: BotActivityView(botId: botId)
            case .terminal: TerminalScreen(botId: botId)
            case .messages: ChatView(botId: botId)
            case .info: BotInfoView(botId: botId)
            }
        }
        .navigationTitle(store.bot(botId)?.name ?? "Bot")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let bot = store.bot(botId) { StateBadge(state: bot.state) }
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .onAppear { store.markSeen(botId) }
        .onDisappear { store.markSeen(botId) }
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
                            Text(bot.name).font(.title3.weight(.semibold))
                            Text(store.projectName(bot.projectId)).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("State") { StateBadge(state: bot.state) }
                    if !bot.stateReason.isEmpty {
                        LabeledContent("Reason", value: bot.stateReason)
                    }
                    if let creator = bot.createdByBotId.flatMap(store.bot) {
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
