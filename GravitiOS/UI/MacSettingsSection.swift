import SwiftUI

/// Screen Sharing sign-in and the file browser's status.
struct MacSettingsSection: View {
    @Environment(AppStore.self) private var store
    @Environment(LensStore.self) private var lens
    @State private var host = ""
    @State private var port = "5900"
    @State private var username = ""
    @State private var password = ""
    @State private var hasPassword = ScreenSettings.password != nil
    @State private var filesStatus = "Checking…"

    var body: some View {
        Section {
            TextField("Address (empty: same as the daemon)", text: $host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            TextField("Port", text: $port).keyboardType(.numberPad)
            TextField("Mac user name", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.username)
            SecureField(hasPassword ? "Password (saved)" : "Mac password", text: $password)
                .textContentType(.password)
            Button("Save") { save() }
                .disabled(username.isEmpty || (password.isEmpty && !hasPassword))
        } header: {
            Text("Mac screen")
        } footer: {
            Text("Turn on Screen Sharing on the Mac: System Settings → General → Sharing → Screen Sharing, and allow your user. Sign in here with that Mac account. The password stays in this iPhone's Keychain and only goes to the Mac.")
        }
        .onAppear(perform: loadSettings)

        Section {
            LabeledContent("File browser", value: filesStatus)
        } footer: {
            Text("To browse the Mac's files, run on the Mac: companion/install.sh --with-files. Needs a device with the control grant.")
        }
        .task { await checkFiles() }
    }

    private func loadSettings() {
        let settings = ScreenSettings.load(defaultHost: "")
        host = settings.host
        port = String(settings.port)
        username = settings.username
    }

    private func save() {
        ScreenSettings(host: host.trimmingCharacters(in: .whitespaces), port: Int(port) ?? 5900,
                       username: username.trimmingCharacters(in: .whitespaces)).save()
        if !password.isEmpty {
            Keychain.save(password, account: ScreenSettings.passwordAccount)
            password = ""
            hasPassword = true
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func checkFiles() async {
        do {
            let root = try await lens.folder("", hidden: false)
            filesStatus = "On: " + root.roots.joined(separator: ", ")
        } catch {
            filesStatus = "Off"
        }
    }
}
