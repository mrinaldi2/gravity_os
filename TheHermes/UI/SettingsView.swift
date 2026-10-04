import SwiftUI

/// The app's own settings. Everything that belongs to one computer (its
/// addresses, token, screen sharing, daemon and Lens) is on its page in the
/// Computers tab.
struct SettingsView: View {
    @AppStorage("terminalFontSize") private var fontSize = 11.0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("Font size \(Int(fontSize)) pt", value: $fontSize, in: 8...18, step: 1)
                } header: {
                    SectionTitle("Terminal")
                } footer: {
                    Text("Opening a bot's terminal resizes it to fit this screen. The terminal is shared, so Hermes on the computer shows that size too until it resizes it again.").foregroundStyle(Color.secondaryText)
                }

                Section {
                    Label("Computers, their screens and tokens are in the Computers tab.", systemImage: "desktopcomputer")
                        .font(.footnote)
                        .foregroundStyle(Color.secondaryText)
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
                    SectionTitle("About")
                } footer: {
                    Text("The Hermes is open source under the MIT License. Based on Gravity by P. Mikołajczuk.").foregroundStyle(Color.secondaryText)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
