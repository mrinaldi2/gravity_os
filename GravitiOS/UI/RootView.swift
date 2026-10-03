import SwiftUI

struct RootView: View {
    @Environment(Fleet.self) private var fleet
    @Environment(Computer.self) private var computer
    @Environment(AppStore.self) private var store
    @Environment(LensStore.self) private var lens
    @State private var tab = Tab.activity
    @State private var openDecision: String?
    @State private var focusPermission: String?
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
            BotsView()
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
        .task { Notifier.requestPermission() }
        .task(id: computer.id) { await lens.poll() }
        // A tapped "needs your permission" notification: its computer, its card.
        .onChange(of: router.target, initial: true) { _, target in
            guard let target, let source = fleet.computers.first(where: { $0.id == target.computerId }) else { return }
            fleet.select(source)
            tab = .decisions
            focusPermission = target.permissionId
            router.target = nil
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
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
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
