import SwiftUI

/// A project is only a name; its folder is derived from it once and never moves.
struct NewProjectSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let created: (Project, _ addBot: Bool) -> Void
    @State private var name = ""
    @State private var addBot = true
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Project name", text: $name)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(create)
                } footer: {
                    Text("Its bots share a folder of artifacts on \(store.computerName): ~/.gravity/projects/<name>.")
                }
                Section {
                    Toggle("Add a first bot next", isOn: $addBot)
                }
            }
            .navigationTitle("New project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else { Button("Create", action: create).disabled(trimmed.isEmpty) }
                }
            }
            .disabled(busy)
            .errorAlert($error)
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }

    private func create() {
        guard !trimmed.isEmpty, !busy else { return }
        busy = true
        Task {
            do {
                let project = try await store.createProject(name: trimmed)
                created(project, addBot)
            } catch {
                self.error = error.localizedDescription
                busy = false
            }
        }
    }
}

/// A bot needs only its project. It starts running as soon as it is created;
/// the charter can be written now or left for the bot to ask about.
struct NewBotSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let created: (Bot) -> Void
    @State private var projectId: String
    @State private var name = ""
    @State private var description = ""
    @State private var instructions = ""
    /// nil: the daemon deals a random icon.
    @State private var avatar: String?
    @State private var busy = false
    @State private var error: String?

    init(projectId: String?, created: @escaping (Bot) -> Void) {
        _projectId = State(initialValue: projectId ?? "")
        self.created = created
    }

    private var bots: Int { store.bots.filter { $0.projectId == projectId }.count }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Project", selection: $projectId) {
                        ForEach(store.sortedProjects) { Text($0.name).tag($0.id) }
                    }
                    TextField("Name (empty: New Bot)", text: $name)
                        .textInputAutocapitalization(.words)
                } footer: {
                    if bots >= 12 {
                        Text("This project already has 12 bots, the most Gravity allows. Delete one on \(store.computerName) first.")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    TextField("One line: what this bot is for", text: $description, axis: .vertical)
                        .lineLimit(1...3)
                    TextField("Standing instructions", text: $instructions, axis: .vertical)
                        .lineLimit(4...12)
                } header: {
                    Text("Charter")
                } footer: {
                    Text("Optional. Without one, the bot asks you what it is for and writes the answer down itself. It can change its own charter later.")
                }

                Section("Avatar") {
                    AvatarPicker(selection: $avatar)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("New bot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else { Button("Create", action: create).disabled(projectId.isEmpty || bots >= 12) }
                }
            }
            .disabled(busy)
            .errorAlert($error)
            .onAppear {
                if projectId.isEmpty { projectId = store.sortedProjects.first?.id ?? "" }
            }
        }
    }

    private func create() {
        guard !projectId.isEmpty, !busy else { return }
        busy = true
        Task {
            do {
                let bot = try await store.createBot(
                    projectId: projectId,
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                    instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines),
                    avatar: avatar)
                created(bot)
            } catch {
                self.error = error.localizedDescription
                busy = false
            }
        }
    }
}

/// Gravity's twenty icons, plus "any" for a random one.
private struct AvatarPicker: View {
    @Binding var selection: String?

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
            Button { selection = nil } label: {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 44, height: 44)
                    .overlay { Image(systemName: "shuffle").foregroundStyle(.secondary) }
                    .overlay(ring(selection == nil))
            }
            .accessibilityLabel("Random avatar")
            ForEach(AvatarView.icons, id: \.self) { icon in
                Button { selection = "icon:\(icon)" } label: {
                    AvatarView(avatar: "icon:\(icon)", name: icon, size: 44)
                        .overlay(ring(selection == "icon:\(icon)"))
                }
                .accessibilityLabel("Avatar \(icon)")
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 6)
    }

    private func ring(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .stroke(selected ? Color.accentColor : .clear, lineWidth: 3)
            .padding(-3)
    }
}
