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
                    Text("Daemon")
                } footer: {
                    Text("The computer running Gravity, as Tailscale shows it. The daemon must list that Tailscale address under bind in \(configPath).")
                }

                Section {
                    SecureField("Device token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Device token")
                } footer: {
                    Text("In Gravity on that computer: Settings → Devices → add a device with read, control and approve. The token is shown once. It is stored in this iPhone's Keychain.")
                }

                Section {
                    Button("Connect") { connect() }
                        .disabled(!valid)
                }
            }
            .navigationTitle(adding ? "Add a computer" : "Connect to Gravity")
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
        fleet.add(record, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        dismiss()
    }
}
