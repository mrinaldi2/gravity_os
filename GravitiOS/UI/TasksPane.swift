import SwiftUI

/// What the bot is doing, waiting on, has scheduled, and has finished:
/// Gravity's Tasks tab, on the phone.
struct BotTasksPane: View {
    @Environment(AppStore.self) private var store
    let botId: String
    @State private var tasks: [BotTask] = []
    /// Open tasks all load; closed ones a page at a time.
    @State private var closedLimit = Page.size
    @State private var moreClosed = false
    @State private var routines: [Routine] = []
    @State private var error: String?
    @State private var loaded = false

    private var now: [BotTask] { tasks.filter { $0.isOpen && $0.role == "assigned" } }
    private var waiting: [BotTask] { tasks.filter { $0.isOpen && $0.role == "delegated" } }
    private var done: [BotTask] { tasks.filter { !$0.isOpen } }
    /// Enabled routines with a next run, soonest first.
    private var upcoming: [Routine] {
        routines.filter { $0.enabled && $0.nextRunAt != nil }.sorted { $0.nextRunAt! < $1.nextRunAt! }
    }

    var body: some View {
        List {
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if loaded, error == nil, tasks.isEmpty, upcoming.isEmpty {
                Text("No tasks yet. Work \(store.bot(botId)?.name ?? "this bot") is given or hands out shows up here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            section("Now", now)
            section("Waiting on others", waiting)
            if !upcoming.isEmpty {
                Section {
                    ForEach(upcoming) { UpcomingRow(routine: $0) }
                } header: {
                    header("Upcoming", upcoming.count)
                }
            }
            section("Done", done)
            if moreClosed {
                ShowMoreButton {
                    closedLimit += Page.size
                    await load()
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
        .task(id: store.status) { await load() }
        // Tasks open and close through bus messages and routine runs: refetch
        // after a burst rather than on every frame of it.
        .task(id: store.busRevision) {
            guard loaded else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    @ViewBuilder private func section(_ title: String, _ list: [BotTask]) -> some View {
        if !list.isEmpty {
            Section {
                ForEach(list) { TaskRowView(botId: botId, task: $0) }
            } header: {
                header(title, list.count)
            }
        }
    }

    private func header(_ title: String, _ count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Text("\(count)").foregroundStyle(.secondary)
        }
    }

    private func load() async {
        guard store.status == .connected else { return }
        do {
            async let listed = store.listTasks(botId: botId, closedLimit: closedLimit)
            async let scheduled = store.listRoutines(botId: botId)
            (tasks, moreClosed) = try await listed
            routines = try await scheduled
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }
}

/// One task: who it is with, what was asked, and how it ended. The list holds
/// previews; opening it loads the whole request and result when the preview
/// was cut, and shows them as the markdown bots write.
private struct TaskRowView: View {
    @Environment(AppStore.self) private var store
    let botId: String
    let task: BotTask
    @State private var open = false
    @State private var full: BotTask?
    @State private var error: String?
    @State private var loading = false

    private var shown: BotTask { full ?? task }

    private var when: String {
        if task.isOpen {
            return task.deadlineAt.map { "due \(TaskTime.text($0))" } ?? ""
        }
        return task.closedAt.map(TaskTime.text) ?? ""
    }

    /// Two lines may hide some of the request, or the daemon cut it, or there is a result to see.
    private var hasMore: Bool {
        task.cut || task.result != nil || task.request.count > 110 || task.request.contains("\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(task.counterpart).font(.subheadline.weight(.semibold)).lineLimit(1)
                if !task.isOpen { TaskBadge(state: task.state) }
                Spacer()
                Text(when).font(.caption).foregroundStyle(.secondary)
            }
            if open {
                MarkdownText(shown.request)
                if let result = shown.result, !result.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Result", systemImage: "checkmark.seal").font(.caption.weight(.semibold)).foregroundStyle(.green)
                        MarkdownText(result)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                if loading { ProgressView().controlSize(.small) }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Button("Show less") { open = false }.font(.caption).buttonStyle(.borderless)
            } else {
                Text(task.request).font(.callout).lineLimit(2)
                if hasMore {
                    Button("Show more") { Task { await expand() } }.font(.caption).buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func expand() async {
        open = true
        guard task.cut, full == nil else { return }
        loading = true
        defer { loading = false }
        do {
            full = try await store.task(botId: botId, taskId: task.id)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct TaskBadge: View {
    let state: String

    private var tint: Color {
        switch state {
        case "done": .green
        case "cancelled": .secondary
        default: .orange
        }
    }

    var body: some View {
        Text(state)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

/// A routine's next scheduled run.
private struct UpcomingRow: View {
    let routine: Routine
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Routine \(routine.name)").font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                Text(routine.nextRunAt.map(TaskTime.text) ?? "").font(.caption).foregroundStyle(.secondary)
            }
            Text(routine.prompt).font(.callout).lineLimit(open ? nil : 2)
            if routine.prompt.count > 110 || routine.prompt.contains("\n") {
                Button(open ? "Show less" : "Show more") { open.toggle() }.font(.caption).buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }
}

enum TaskTime {
    static func text(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }
}
