import SwiftUI

/// The toolbar menu that picks which computer the tabs show. Hidden with
/// only one computer.
struct ComputerSwitcher: View {
    @Environment(Fleet.self) private var fleet
    @Environment(Computer.self) private var current
    @State private var adding = false

    /// Another computer has decisions waiting or a bot asking for approval.
    private var othersNeedYou: Bool {
        fleet.computers.contains { $0.id != current.id && needsYou($0) }
    }

    var body: some View {
        if fleet.computers.count > 1 {
            Menu {
                ForEach(fleet.computers) { computer in
                    Button { fleet.select(computer) } label: {
                        Label(title(computer), systemImage: computer.id == current.id ? "checkmark" : computer.kind.symbol)
                    }
                }
                Divider()
                Button { adding = true } label: { Label("Add a computer", systemImage: "plus") }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: current.kind.symbol)
                    Text(current.name).lineLimit(1)
                    if othersNeedYou { Circle().fill(.orange).frame(width: 7, height: 7) }
                }
                .font(.subheadline.weight(.medium))
            }
            .accessibilityLabel("Computer: \(current.name)")
            .sheet(isPresented: $adding) { ConnectView(adding: true) }
        }
    }

    private func needsYou(_ computer: Computer) -> Bool {
        computer.store.pendingCounts.total > 0 || !computer.store.approvals.isEmpty
    }

    private func title(_ computer: Computer) -> String {
        var parts = [computer.name]
        if computer.store.status != .connected { parts.append(computer.store.status.label) }
        let pending = computer.store.pendingCounts.total
        if pending > 0 { parts.append(pending == 1 ? "1 decision" : "\(pending) decisions") }
        return parts.joined(separator: " · ")
    }
}

/// Every computer the phone knows, in Settings.
struct ComputersSection: View {
    @Environment(Fleet.self) private var fleet
    @State private var adding = false

    var body: some View {
        Section {
            ForEach(fleet.computers) { computer in
                NavigationLink {
                    ComputerEditor(computer: computer)
                } label: {
                    HStack {
                        Label(computer.name, systemImage: computer.kind.symbol)
                        Spacer()
                        Text(computer.store.status.label).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Button { adding = true } label: { Label("Add a computer", systemImage: "plus") }
        } header: {
            Text("Computers")
        } footer: {
            Text("Every computer stays connected, so notifications and decisions come from all of them. The menu at the top of each tab picks the one on screen.")
        }
        .sheet(isPresented: $adding) { ConnectView(adding: true) }
    }
}

/// A computer's name, addresses and token.
struct ComputerEditor: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.dismiss) private var dismiss
    let computer: Computer
    @State private var record: ComputerRecord
    @State private var port: String
    @State private var lensPort: String
    @State private var token = ""
    @State private var confirmRemove = false

    init(computer: Computer) {
        self.computer = computer
        _record = State(initialValue: computer.record)
        _port = State(initialValue: String(computer.record.port))
        _lensPort = State(initialValue: String(computer.record.lensPort))
    }

    private var edited: ComputerRecord {
        var result = record
        result.name = record.name.trimmingCharacters(in: .whitespaces)
        result.host = record.host.trimmingCharacters(in: .whitespaces)
        result.lensHost = record.lensHost.trimmingCharacters(in: .whitespaces)
        result.port = Int(port) ?? record.port
        result.lensPort = Int(lensPort) ?? record.lensPort
        return result
    }

    private var valid: Bool { !edited.name.isEmpty && !edited.host.isEmpty && Int(port) != nil && Int(lensPort) != nil }

    var body: some View {
        Form {
            Section("Computer") {
                TextField("Name", text: $record.name)
                Picker("Type", selection: $record.kind) {
                    Text("Mac").tag(ComputerKind.mac)
                    Text("Windows").tag(ComputerKind.windows)
                }
            }
            Section {
                TextField("Tailscale name or 100.x.y.z", text: $record.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                LabeledContent("Port") {
                    TextField("49777", text: $port).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Daemon")
            }
            Section {
                TextField("Address (empty: same as the daemon)", text: $record.lensHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                LabeledContent("Port") {
                    TextField("49778", text: $lensPort).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Gravity Lens")
            }
            Section {
                Button("Save") {
                    fleet.update(computer, edited)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
                .disabled(!valid || edited == computer.record)
            }
            Section {
                SecureField("New device token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Replace token") {
                    computer.setToken(token.trimmingCharacters(in: .whitespacesAndNewlines))
                    token = ""
                }
                .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                Text("For a token that was revoked or rejected. Create one in Gravity on \(computer.name): Settings → Devices.")
            }
            Section {
                Button("Remove \(computer.name)", role: .destructive) { confirmRemove = true }
            } footer: {
                Text("Removes its token and screen password from this iPhone. To cut off a lost phone, revoke the device in Gravity on that computer.")
            }
        }
        .navigationTitle(computer.name)
        .confirmationDialog("Remove \(computer.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                dismiss()
                fleet.remove(computer)
            }
        }
    }
}
