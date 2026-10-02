import SwiftUI

/// Opens a project's Workers screen from the Bots list.
struct WorkersLink: Hashable {
    let projectId: String
}

/// A project's temporary workers: those running, the queue waiting for a
/// slot, and those that recently finished. Follows `workers_updated`.
struct WorkersView: View {
    @Environment(AppStore.self) private var store
    let projectId: String
    @State private var listing: WorkerListing?
    @State private var error: String?
    @State private var cancelling: Worker?
    @State private var openBot: String?

    var body: some View {
        let sections = Worker.sections(listing?.workers ?? [])
        List {
            if let listing {
                Section {
                    Text("\(listing.runningHere) of \(listing.maxHere) slots in use here")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if listing.workers.isEmpty {
                        Text("No workers yet. Bots spawn temporary workers for pieces of a larger job; they wait here when every slot is busy.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            section("Running", sections.running)
            section("Queued", sections.queued)
            section("Finished", sections.finished)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Workers")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if listing == nil, error == nil { ProgressView() } }
        .refreshable { await load() }
        .task(id: store.status) { await load() }
        // Refetched when the daemon says this project's queue changed, and only then.
        .task(id: store.workersRevision[projectId]) {
            guard listing != nil else { return }
            await load()
        }
        .confirmationDialog("Cancel \(cancelling?.name ?? "this worker")?", isPresented: Binding(
            get: { cancelling != nil }, set: { if !$0 { cancelling = nil } }), titleVisibility: .visible
        ) {
            if let worker = cancelling {
                Button(worker.state == "queued" ? "Drop it from the queue" : "Stop it", role: .destructive) {
                    cancel(worker)
                }
            }
        } message: {
            Text(cancelling?.state == "queued"
                 ? "It has not started; it leaves the queue."
                 : "It is told to stop, in your name, and retires.")
        }
        .navigationDestination(item: $openBot) { BotDetailView(botId: $0) }
    }

    @ViewBuilder private func section(_ title: String, _ workers: [Worker]) -> some View {
        if !workers.isEmpty {
            Section {
                ForEach(workers) { worker in row(worker) }
            } header: {
                HStack(spacing: 6) {
                    Text(title)
                    Text("\(workers.count)").foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func row(_ worker: Worker) -> some View {
        let canCancel = worker.isActive && store.canControl && store.status == .connected
        // A running worker opens its bot, when that bot is listed here.
        let bot = worker.state == "running" ? worker.botId.flatMap(store.bot) : nil
        WorkerRow(worker: worker, opens: bot != nil)
            .contentShape(Rectangle())
            .onTapGesture { if let bot { openBot = bot.id } }
            .swipeActions {
                if canCancel {
                    Button("Cancel", role: .destructive) { cancelling = worker }
                }
            }
            .contextMenu {
                if canCancel {
                    Button("Cancel \(worker.name)", systemImage: "xmark.circle", role: .destructive) { cancelling = worker }
                }
            }
    }

    private func load() async {
        guard store.status == .connected else { return }
        do {
            listing = try await store.listWorkers(projectId: projectId)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func cancel(_ worker: Worker) {
        Task {
            do {
                try await store.cancelWorker(worker.id)
                await load()
            } catch {
                self.error = error.localizedDescription
                await load()
            }
        }
    }
}

private struct WorkerRow: View {
    let worker: Worker
    /// Tapping opens its bot.
    let opens: Bool

    private var tint: Color {
        switch worker.state {
        case "running": .accentColor
        case "queued": .orange
        case "done": .green
        case "failed": .red
        default: .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(worker.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(worker.chip)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .foregroundStyle(tint)
                    .background(tint.opacity(0.15), in: Capsule())
                Spacer(minLength: 4)
                if let when = worker.when { Text(when.relative).font(.caption).foregroundStyle(.secondary) }
                if opens { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
            }
            if let parent = worker.parentName {
                Text("for \(parent)").font(.caption).foregroundStyle(.secondary)
            }
            if !worker.brief.isEmpty {
                Text(worker.brief).font(.callout).lineLimit(2)
            }
            if let note = worker.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A project's shared git repository: workers start from its branch and
/// push their work back to it.
struct RepoSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let projectId: String
    @State private var url = ""
    @State private var branch = "main"
    @State private var busy = false
    @State private var failure: String?

    private var project: Project? { store.projects.first { $0.id == projectId } }
    private var trimmedURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedBranch: String {
        let value = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "main" : value
    }
    private var dirty: Bool {
        !trimmedURL.isEmpty && (trimmedURL != project?.repo?.url || trimmedBranch != project?.repo?.branch)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("git@github.com:you/project.git", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("Clone URL")
                }
                Section {
                    TextField("main", text: $branch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Branch")
                } footer: {
                    Text("Each worker a bot spawns clones this branch when it starts and pushes its work back before it reports. Whatever a worker leaves unpushed is saved to a branch of its own. Each computer uses its own git credentials.")
                }
                if project?.repo != nil {
                    Section {
                        Button("Remove", role: .destructive) { save(url: nil) }
                            .disabled(busy || !store.canControl)
                    }
                }
            }
            .disabled(!store.canControl)
            .navigationTitle("Shared repository")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("Save") { save(url: trimmedURL) }
                            .disabled(!dirty || !store.canControl)
                    }
                }
            }
            .errorAlert($failure)
            .onAppear {
                url = project?.repo?.url ?? ""
                branch = project?.repo?.branch ?? "main"
            }
        }
    }

    private func save(url: String?) {
        busy = true
        Task {
            do {
                // A bad URL or branch comes back as invalid_request with a readable message.
                try await store.setProjectRepo(projectId, url: url, branch: trimmedBranch)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
            busy = false
        }
    }
}
