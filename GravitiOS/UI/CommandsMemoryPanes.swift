import SwiftUI

/// Everything the bot is running as commands, and what it ran: foreground and
/// background, with each command's output. The newest page at first, more on
/// request. Refetched as the bot works, and polled while a background command
/// is still writing output.
struct CommandsPane: View {
    @Environment(AppStore.self) private var store
    let botId: String
    @State private var commands: [BotCommand] = []
    @State private var limit = Page.size
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        let sections = BotCommand.sections(commands)
        List {
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if loaded, commands.isEmpty, error == nil {
                Text("\(store.bot(botId)?.name ?? "This bot") has not run any commands yet.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            section("Running", sections.running)
            section("Finished", sections.finished)
            // A full page means there may be older ones.
            if commands.count >= limit {
                ShowMoreButton {
                    limit += Page.size
                    await load()
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
        .task(id: store.status) { await load() }
        // A working bot changes its chat constantly: refetch once it pauses,
        // not on every step, so a slow link is not kept full.
        .task(id: store.chatRevision[botId]) {
            guard loaded else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await load()
        }
        // A background command's output keeps growing: reread it every few seconds.
        .task(id: BotCommand.needsPolling(commands)) {
            guard BotCommand.needsPolling(commands) else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await load()
            }
        }
    }

    @ViewBuilder private func section(_ title: String, _ list: [BotCommand]) -> some View {
        if !list.isEmpty {
            Section {
                ForEach(list) { CommandRow(command: $0) }
            } header: {
                HStack(spacing: 6) {
                    Text(title)
                    Text("\(list.count)").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func load() async {
        guard store.status == .connected else { return }
        do {
            commands = try await store.botCommands(botId: botId, limit: limit)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }
}

/// One command: what it is for, the command line, and its output on demand.
private struct CommandRow: View {
    let command: BotCommand
    @State private var open = false

    private var dot: Color {
        switch command.status {
        case "running": .accentColor
        case "done": .green
        case "failed": .red
        default: .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // A tap gesture, not a Button: beside the Copy buttons, a List hands
            // a plain button's taps to the row's other buttons.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(dot).frame(width: 8, height: 8)
                Text(command.title).font(.subheadline.weight(.medium)).lineLimit(2)
                Spacer(minLength: 4)
                if command.background { Badge(text: "background", tint: .purple) }
                if let outcome = command.outcome {
                    Badge(text: outcome, tint: command.status == "failed" || outcome.hasPrefix("exit") ? .red : .secondary)
                }
                Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy) { open.toggle() } }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(open ? "Hides the output" : "Shows the whole command and its output")
            if open {
                CopyableBlock(title: "Command", text: command.command)
                if let output = command.copyableOutput {
                    CopyableBlock(title: "Output", text: output)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Output").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Text("No output yet.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(command.command)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contextMenu { CopyMenuItem(text: command.command) }
                    CopyButton(text: command.command, label: "Copy the command")
                }
            }
            Text(command.when(TaskTime.text)).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// A command or its output, in full, under a small heading with its own Copy.
private struct CopyableBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                CopyButton(text: text, label: "Copy the \(title.lowercased())")
            }
            // Wrapped, so nothing is cut off at the screen's edge.
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contextMenu { CopyMenuItem(text: text) }
        }
    }
}

/// Puts the exact text on the clipboard and says so for a moment.
private struct CopyButton: View {
    let text: String
    let label: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.snappy) { copied = true }
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(copied ? Color.green : Color.accentColor)
        }
        // Its own tap target in a List row, not the row's.
        .buttonStyle(.borderless)
        .accessibilityLabel(copied ? "Copied" : label)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.snappy) { copied = false }
        }
    }
}

/// Long-press to copy.
private struct CopyMenuItem: View {
    let text: String

    var body: some View {
        Button {
            UIPasteboard.general.string = text
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
    }
}

private struct Badge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

/// What the bot keeps in FACTS.md: the durable facts it carries between
/// sessions. Read-only; the bot owns the file. Reread after its turns change,
/// since that is when it writes.
struct MemoryPane: View {
    @Environment(AppStore.self) private var store
    let botId: String
    @State private var memory = Memory.loading

    static let file = "FACTS.md"

    enum Memory: Equatable {
        case loading
        case loaded(text: String, truncated: Bool)
        /// The bot has not written any yet.
        case missing
        case failed(String)
    }

    private var name: String { store.bot(botId)?.name ?? "This bot" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(Self.file, systemImage: "brain").font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") { Task { await load() } }
                        .font(.caption)
                        .disabled(store.status != .connected)
                }
                switch memory {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity)
                case .missing:
                    Text("\(name) has not written any memory yet.").foregroundStyle(.secondary)
                case .failed(let error):
                    Text(error).font(.footnote).foregroundStyle(.red)
                case .loaded(let text, let truncated):
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("\(name)'s memory is empty.").foregroundStyle(.secondary)
                    } else {
                        MarkdownText(text).textSelection(.enabled)
                    }
                    if truncated {
                        Text("Only the start of the file is shown.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .refreshable { await load() }
        .task(id: store.status) { await load() }
        .task(id: store.chatRevision[botId]) {
            guard memory != .loading else { return }
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    private func load() async {
        guard store.status == .connected else { return }
        do {
            let file = try await store.readFile(botId: botId, path: Self.file)
            memory = .loaded(text: file.text ?? "", truncated: file.truncated)
        } catch {
            // "File not found" means no memory yet, not a failure.
            let message = error.localizedDescription
            memory = message.localizedCaseInsensitiveContains("not found") ? .missing : .failed(message)
        }
    }
}
