import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(LensStore.self) private var lens
    @State private var tab = Tab.activity
    @State private var openDecision: String?

    enum Tab { case activity, bots, decisions, reports, mac }

    var body: some View {
        TabView(selection: $tab) {
            FeedView()
                .tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }
                .tag(Tab.activity)
            BotsView()
                .tabItem { Label("Bots", systemImage: "person.2") }
                .tag(Tab.bots)
            DecisionsView(openDecision: $openDecision)
                .tabItem { Label("Decisions", systemImage: "checklist") }
                .badge(store.pendingCounts.total)
                .tag(Tab.decisions)
            ReportsView()
                .tabItem { Label("Reports", systemImage: "doc.richtext") }
                .tag(Tab.reports)
            MacView()
                .tabItem { Label("Mac", systemImage: "laptopcomputer") }
                .tag(Tab.mac)
        }
        .overlay(alignment: .top) { noticeBanner }
        .animation(.snappy, value: store.notice)
        .task { Notifier.requestPermission() }
        .task { await lens.poll() }
    }

    @ViewBuilder private var noticeBanner: some View {
        if let notice = store.notice {
            Button {
                if let id = notice.decisionId {
                    tab = .decisions
                    openDecision = id
                }
                store.notice = nil
            } label: {
                VStack(alignment: .leading, spacing: 2) {
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
                if store.notice?.id == notice.id { store.notice = nil }
            }
        }
    }
}
