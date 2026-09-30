import SwiftUI

/// First-run screen: where the daemon is and the device token to use.
struct ConnectView: View {
    @Environment(AppStore.self) private var store
    @State private var host = ""
    @State private var port = "49777"
    @State private var token = ""

    private var valid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && Int(port) != nil
            && !token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Tailscale name or 100.x.y.z", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Port", text: $port).keyboardType(.numberPad)
                } header: {
                    Text("Daemon")
                } footer: {
                    Text("The Mac running Gravity, as Tailscale shows it. The daemon must list that Tailscale address under bind in ~/.gravity/gravityd.toml.")
                }

                Section {
                    SecureField("Device token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Device token")
                } footer: {
                    Text("In Gravity on the Mac: Settings → Devices → add a device with read, control and approve. The token is shown once. It is stored in this iPhone's Keychain.")
                }

                Section {
                    Button("Connect") {
                        store.connect(Endpoint(
                            host: host.trimmingCharacters(in: .whitespaces),
                            port: Int(port) ?? 49777,
                            token: token.trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                    .disabled(!valid)
                }
            }
            .navigationTitle("Connect to Gravity")
        }
    }
}
