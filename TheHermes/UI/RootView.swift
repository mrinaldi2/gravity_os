import SwiftUI

/// The app's tabs (UX-024): Projects · Needs you · Chat · Settings.
struct RootView: View {
    @Environment(Fleet.self) private var fleet
    @Environment(Computer.self) private var computer
    @Environment(AppStore.self) private var store
    @Environment(LensStore.self) private var lens
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var tab = Tab.projects
    @State private var openNeeds: NeedsDestination?
    @State private var openBot: BotLink?
    @State private var explaining = false
    private var router: NotificationRouter { .shared }

    enum Tab { case projects, needs, chat, settings }

    var body: some View {
        Group {
            if sizeClass == .regular {
                // iPad (UX-024): the sidebar holds Needs you, Chat and the ranked projects.
                PadRootView(tab: $tab, openNeeds: $openNeeds, openBot: $openBot)
            } else {
                tabs
            }
        }
        .overlay(alignment: .top) { noticeBanner }
        // "See all in Needs you" on a project's Overview.
        .onChange(of: fleet.home.needsFocus) { _, id in if id != nil { tab = .needs } }
        .animation(.snappy, value: fleet.notice?.1)
        // Asked after pairing, with a word on why, before the system prompt.
        .task { explaining = await NotificationExplainer.shouldExplain() }
        .sheet(isPresented: $explaining) { NotificationExplainer() }
        .task(id: computer.id) { await lens.poll() }
        #if DEBUG
        // Checks without tapping a notification: -route kind/id[/bot] acts as one.
        .task {
            guard let route = UserDefaults.standard.string(forKey: "route") else { return }
            let parts = route.split(separator: "/").map(String.init)
            guard parts.count >= 2 else { return }
            router.target = NotificationTarget(userInfo: ["computer": computer.id, "kind": parts[0], "id": parts[1],
                                                          "bot": parts.count > 2 ? parts[2] : ""])
        }
        // Screenshots of a tab: -openTab needs|chat|settings.
        .task {
            switch UserDefaults.standard.string(forKey: "openTab") {
            case "needs": tab = .needs
            case "chat": tab = .chat
            case "settings": tab = .settings
            default: break
            }
        }
        #endif
        // A tapped notification: its computer, then what it is about.
        .onChange(of: router.target, initial: true) { _, target in
            guard let target else { return }
            router.target = nil
            guard let source = fleet.computers.first(where: { $0.id == target.computerId }),
                  let destination = target.destination else { return }
            fleet.select(source)
            open(destination, on: source)
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            ProjectsHomeView()
                .tabItem { Label("Projects", systemImage: "square.grid.2x2") }
                .tag(Tab.projects)
            NeedsYouView(openDecision: $openNeeds)
                .tabItem { Label("Needs you", systemImage: "exclamationmark.bubble") }
                .badge(fleet.home.total(fleet.computers))
                .tag(Tab.needs)
            MainChatView(openBot: $openBot)
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                .tag(Tab.chat)
            SettingsView(inTab: true)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .badge(fleet.computers.filter { $0.store.status != .connected && $0.store.status != .connecting }.count)
                .tag(Tab.settings)
        }
    }

    private func open(_ destination: NotificationTarget.Destination, on source: Computer) {
        switch destination {
        case .decision(let id):
            tab = .needs
            openNeeds = .decision(computerId: source.id, decisionId: id)
        case .permissionCard(let id):
            tab = .needs
            if let bot = source.store.permissions.first(where: { $0.id == id })?.botId {
                openNeeds = .bot(computerId: source.id, botId: bot, chat: false)
            }
        case .bot(let id, let pane):
            tab = .chat
            openBot = BotLink(botId: id, pane: pane)
        }
    }

    @ViewBuilder private var noticeBanner: some View {
        if case let (source, notice)? = fleet.notice {
            Button {
                if let id = notice.decisionId {
                    tab = .needs
                    openNeeds = .decision(computerId: source.id, decisionId: id)
                }
                source.store.notice = nil
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    if fleet.computers.count > 1 {
                        Label(source.name, systemImage: source.kind.symbol)
                            .font(.caption.weight(.medium)).foregroundStyle(Color.secondaryText)
                    }
                    Text(notice.title).font(.subheadline.weight(.semibold))
                    if !notice.body.isEmpty {
                        Text(notice.body).font(.footnote).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 12)
            }
            .buttonStyle(.plain)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: notice.id) {
                try? await Task.sleep(for: .seconds(5))
                if source.store.notice?.id == notice.id { source.store.notice = nil }
            }
        }
    }
}
