import SwiftUI

/// Opens Settings as a sheet: it is visited rarely, so it has no tab.
struct SettingsButton: View {
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: { Image(systemName: "gearshape") }
            .accessibilityLabel("Settings")
            .sheet(isPresented: $showing) { SettingsView() }
    }
}
