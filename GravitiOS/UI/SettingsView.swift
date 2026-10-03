import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(LensStore.self) private var lens
    @State private var diagnostics: Diagnostics?
    @State private var addingComputer = false
    @AppStorage("terminalFontSize") private var fontSize = 11.0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                ComputersSection(adding: $addingComputer)
                MacSettingsSection()
                Section("\(store.computerName): connection") {
                    LabeledContent("Status", value: store.status.label)
                    if let endpoint = store.endpoint {
                        LabeledContent("Daemon", value: "\(endpoint.host):\(endpoint.port)")
                    }
                    if !store.serverVersion.isEmpty {
                        LabeledContent("Daemon version", value: store.serverVersion)
                    }
                    LabeledContent("Grants", value: store.grants.sorted().joined(separator: ", "))
                    if case .disconnected(let reason) = store.status {
                        Text(reason).font(.footnote).foregroundStyle(.secondary)
                        Button("Reconnect now") { store.client.reconnectNow() }
                    }
                    if case .authFailed(let reason) = store.status {
                        Text(reason).font(.footnote).foregroundStyle(.red)
                    }
                    if case .versionMismatch(let reason) = store.status {
                        Text(reason).font(.footnote).foregroundStyle(.red)
                    }
                }

                if let diagnostics {
                    Section("\(store.computerName): daemon") {
                        LabeledContent("Active bots", value: "\(diagnostics.activeBots)")
                        LabeledContent("Runtime", value: diagnostics.runtimeAvailable
                            ? diagnostics.runtimeKind : "\(diagnostics.runtimeKind) (unavailable)")
                        LabeledContent("Database", value: diagnostics.dbHealthy ? "Healthy" : "Degraded")
                        LabeledContent("Delivery backlog", value: "\(diagnostics.deliveryBacklog)")
                        LabeledContent("Uptime", value: uptime(diagnostics.uptimeSeconds))
                        if diagnostics.staleBuild {
                            Label("The daemon was updated on disk and needs a restart.", systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section {
                    LabeledContent("Status", value: lens.status.label)
                    if case .unreachable(let reason) = lens.status {
                        Text(reason).font(.footnote).foregroundStyle(.secondary)
                    }
                    LabeledContent("Port", value: String(lens.port))
                    Button("Check now") { Task { await lens.refresh() } }
                } header: {
                    Text("\(store.computerName): Gravity Lens")
                } footer: {
                    Text("The companion that turns the bots' logs into the Activity and Reports views. It uses the same device token as the daemon. Change its address under Computers.")
                }

                Section {
                    Stepper("Font size \(Int(fontSize)) pt", value: $fontSize, in: 8...18, step: 1)
                } header: {
                    Text("Terminal")
                } footer: {
                    Text("Opening a bot's terminal resizes it to fit this screen. The terminal is shared, so Gravity on the computer shows that size too until it resizes it again.")
                }

                Section {
                    LabeledContent("Version", value: AppInfo.label)
                        .textSelection(.enabled)
                    if let commit = AppInfo.commit {
                        LabeledContent("Commit", value: commit)
                            .textSelection(.enabled)
                    }
                    Link("Source code", destination: AppInfo.sourceURL)
                    Link("Licenses", destination: AppInfo.noticesURL)
                } header: {
                    Text("About")
                } footer: {
                    Text("GravitiOS is an independent project under the MIT License. It is not made by, affiliated with or endorsed by the Gravity authors.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task(id: store.status) { await loadDiagnostics() }
            .refreshable { await loadDiagnostics() }
            .sheet(isPresented: $addingComputer) { ConnectView(adding: true) }
        }
    }

    private func loadDiagnostics() async {
        guard let reply = try? await store.client.request("diagnostics"),
              let body = reply.dict("diagnostics") else { return }
        diagnostics = Diagnostics(body)
    }

    private func uptime(_ seconds: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds) s"
    }
}
