import SwiftUI

struct RootView: View {
    @Environment(Fleet.self) private var fleet
    @Environment(Computer.self) private var computer
    @Environment(AppStore.self) private var store
    @Environment(LensStore.self) private var lens
    @State private var tab = Tab.activity
    @State private var openDecision: String?
    @State private var focusPermission: String?
    @State private var openBot: BotLink?
    @State private var explaining = false
    private var router: NotificationRouter { .shared }

    enum Tab { case activity, bots, decisions, reports, computers }

    var body: some View {
        TabView(selection: $tab) {
            FeedView { computer in
                fleet.select(computer)
                tab = .decisions
            }
                .tabItem { Label("Home", systemImage: "house") }
                .tag(Tab.activity)
            BotsView(openBot: $openBot)
                .tabItem { Label("Bots", systemImage: "person.2") }
                .tag(Tab.bots)
            DecisionsView(openDecision: $openDecision, focusPermission: $focusPermission)
                .tabItem { Label("Decisions", systemImage: "checklist") }
                .badge(store.decisionsBadge)
                .tag(Tab.decisions)
            ReportsView()
                .tabItem { Label("Files", systemImage: "doc.on.doc") }
                .tag(Tab.reports)
            ComputersView()
                .tabItem { Label("Computers", systemImage: "desktopcomputer") }
                .badge(fleet.computers.filter { $0.store.status != .connected && $0.store.status != .connecting }.count)
                .tag(Tab.computers)
        }
        // Another computer: fresh navigation, since ids belong to one daemon.
        .id(computer.id)
        .overlay(alignment: .top) { noticeBanner }
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
        #endif
        // A tapped notification: its computer, then what it is about.
        .onChange(of: router.target, initial: true) { _, target in
            guard let target else { return }
            router.target = nil
            guard let source = fleet.computers.first(where: { $0.id == target.computerId }),
                  let destination = target.destination else { return }
            fleet.select(source)
            open(destination)
        }
    }

    private func open(_ destination: NotificationTarget.Destination) {
        switch destination {
        case .decision(let id):
            tab = .decisions
            openDecision = id
        case .permissionCard(let id):
            tab = .decisions
            focusPermission = id
        case .bot(let id, let pane):
            tab = .bots
            openBot = BotLink(botId: id, pane: pane)
        }
    }

    @ViewBuilder private var noticeBanner: some View {
        if case let (source, notice)? = fleet.notice {
            Button {
                if let id = notice.decisionId {
                    fleet.select(source)
                    tab = .decisions
                    openDecision = id
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
