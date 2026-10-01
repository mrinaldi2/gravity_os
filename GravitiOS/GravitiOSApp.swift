import SwiftUI

@main
struct GravitiOSApp: App {
    @State private var fleet = Fleet()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if let computer = fleet.selected {
                    RootView()
                        .environment(computer)
                        .environment(computer.store)
                        .environment(computer.lens)
                        .environment(computer.screen)
                } else {
                    ConnectView()
                }
            }
            .environment(fleet)
            .onChange(of: scenePhase) { _, phase in fleet.setBackground(phase != .active) }
        }
    }
}
