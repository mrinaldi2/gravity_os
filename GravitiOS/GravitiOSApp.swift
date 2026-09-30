import SwiftUI

@main
struct GravitiOSApp: App {
    @State private var store: AppStore
    @State private var lens: LensStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = AppStore()
        _store = State(initialValue: store)
        _lens = State(initialValue: LensStore(app: store))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if store.hasEndpoint {
                    RootView()
                } else {
                    ConnectView()
                }
            }
            .environment(store)
            .environment(lens)
            .onChange(of: scenePhase) { _, phase in
                store.inBackground = phase != .active
                if phase == .active { store.client.reconnectNow() }
            }
        }
    }
}
