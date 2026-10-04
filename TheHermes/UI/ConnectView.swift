import SwiftUI

/// Where a computer's daemon is and the device token to use: the first-run
/// screen, and the sheet that adds another computer.
struct ConnectView: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.dismiss) private var dismiss
    /// Shown as a sheet over the app, with a Cancel button.
    var adding = false
    @State private var name = ""
    @State private var kind = ComputerKind.mac
    @State private var host = ""
    @State private var port = "49777"
    @State private var token = ""
    /// Computers to pair the new one with once it is connected.
    @State private var linkWith: Set<String> = []

    /// The computers already here that could be paired with the new one.
    private var linkable: [Computer] {
        fleet.computers.filter { $0.store.status == .connected && $0.store.canControl }
    }

    private var valid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && Int(port) != nil
            && !token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var configPath: String {
        kind == .mac ? "~/.gravity/gravityd.toml" : "%USERPROFILE%\\.gravity\\gravityd.toml"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        Text("Mac").tag(ComputerKind.mac)
                        Text("Windows").tag(ComputerKind.windows)
                    }
                    .pickerStyle(.segmented)
                    TextField("Name (\(kind.label))", text: $name)
                } header: {
                    Text("Computer")
                }

                Section {
                    TextField("Tailscale name or 100.x.y.z", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Port", text: $port).keyboardType(.numberPad)
                } header: {
                    Text("Hermes service")
                } footer: {
                    Text("The computer running The Hermes, as Tailscale shows it. The Hermes service must list that Tailscale address under bind in \(configPath).")
                }

                Section {
                    SecureField("Device token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Device token")
                } footer: {
                    Text("In The Hermes on that computer: Settings → Devices → add a device with read, control and approve. The token is shown once. It is stored in this iPhone's Keychain.")
                }

                if adding, !linkable.isEmpty {
                    Section {
                        ForEach(linkable) { computer in
                            Toggle(isOn: Binding(
                                get: { linkWith.contains(computer.id) },
                                set: { if $0 { linkWith.insert(computer.id) } else { linkWith.remove(computer.id) } })
                            ) {
                                ItemRow(title: computer.name, subtitle: "Its bots can work with the new computer's") {
                                    IconTile(systemImage: computer.kind.symbol, tone: .ready)
                                }
                            }
                        }
                    } header: {
                        Text("Link it with")
                    } footer: {
                        Text("Linked computers can share projects and hand each other tasks. You can change this later under Computers → Network.")
                    }
                }

                Section {
                    Button("Connect") { connect() }
                        .disabled(!valid)
                }
            }
            .navigationTitle(adding ? "Add a computer" : "Connect to The Hermes")
            .onAppear { linkWith = Set(linkable.map(\.id)) }
            .toolbar {
                if adding {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
            }
        }
    }

    private func connect() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let record = ComputerRecord(
            name: trimmed.isEmpty ? kind.label : trimmed, kind: kind,
            host: host.trimmingCharacters(in: .whitespaces), port: Int(port) ?? 49777)
        let added = fleet.add(record, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        let others = fleet.computers.filter { linkWith.contains($0.id) && $0.id != added.id }
        dismiss()
        guard !others.isEmpty else { return }
        // Pairing needs the new computer online: wait for it, briefly.
        Task { @MainActor in
            for _ in 0..<30 where added.store.status != .connected {
                try? await Task.sleep(for: .seconds(1))
            }
            guard added.store.status == .connected else { return }
            for other in others where fleet.peer(of: added, for: other) == nil {
                try? await fleet.connect(added, to: other)
            }
        }
    }
}
