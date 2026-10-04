import SwiftUI
import UserNotifications

/// The app's own settings. Everything that belongs to one computer (its
/// addresses, token, screen sharing, daemon and Lens) is on its page in the
/// Computers tab.
struct SettingsView: View {
    @AppStorage("terminalFontSize") private var fontSize = 11.0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var notifications: UNAuthorizationStatus?

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
                    LabeledContent("Notifications", value: notificationsLabel)
                    if notifications == .notDetermined {
                        Button("Turn on notifications") {
                            UserDefaults.standard.set(true, forKey: NotificationExplainer.shownKey)
                            Task {
                                _ = try? await UNUserNotificationCenter.current()
                                    .requestAuthorization(options: [.alert, .sound, .badge])
                                await refreshNotifications()
                            }
                        }
                    } else {
                        Button("Change in iOS Settings") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                        }
                    }
                } header: {
                    SectionTitle("Notifications")
                } footer: {
                    Text("While The Hermes is open or recently used, it tells you when a bot needs a decision, asks for permission or is waiting for you.").foregroundStyle(Color.secondaryText)
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
            .task { await refreshNotifications() }
            // Coming back from iOS Settings: show what was chosen there.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await refreshNotifications() } }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var notificationsLabel: String {
        switch notifications {
        case .authorized, .provisional, .ephemeral: "On"
        case .denied: "Off"
        case .notDetermined: "Not set up"
        default: ""
        }
    }

    private func refreshNotifications() async {
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
