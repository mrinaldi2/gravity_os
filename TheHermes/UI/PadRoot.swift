import SwiftUI

/// The iPad shell (UX-024): a sidebar with Needs you and Chat, then the
/// projects ranked by how much they need the owner. The main chat also
/// slides over any screen (✉ or ⌘J) without leaving it.
struct PadRootView: View {
    @Environment(Fleet.self) private var fleet
    @Binding var tab: RootView.Tab
    @Binding var openNeeds: NeedsDestination?
    @Binding var openBot: BotLink?
    @State private var selection: Item? = .projects
    @State private var chatPanel = false

    enum Item: Hashable {
        case needs, chat, projects, settings
        case project(HomeProjectLink)
    }

    private var cards: [HomeCard] { fleet.home.cards(fleet.computers) }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Needs you", systemImage: "exclamationmark.bubble")
                    .badge(fleet.home.total(fleet.computers))
                    .tag(Item.needs)
                Label("Chat", systemImage: "bubble.left.and.bubble.right")
                    .tag(Item.chat)
                Section("Projects") {
                    Label("All projects", systemImage: "square.grid.2x2")
                        .tag(Item.projects)
                    ForEach(cards) { card in
                        let link = HomeProjectLink(computerId: card.computerId, projectId: card.row.projectID)
                        let selected = selection == .project(link)
                        HStack(spacing: 8) {
                            if card.rank != nil { RankBadge(rank: card.rank, selected: selected) }
                            Text(card.row.name).lineLimit(1)
                            Spacer(minLength: 4)
                            if card.row.attention.count > 0 {
                                Text("\(card.row.attention.count)")
                                    .font(.caption)
                                    .foregroundStyle(selected ? Color.white : Color.secondaryText)
                                    .accessibilityLabel("\(card.row.attention.count) need you")
                            }
                        }
                        .tag(Item.project(link))
                        .accessibilityElement(children: .combine)
                    }
                }
                Label("Settings", systemImage: "gearshape")
                    .badge(fleet.computers.filter { $0.store.status != .connected && $0.store.status != .connecting }.count)
                    .tag(Item.settings)
            }
            .navigationTitle("The Hermes")
        } detail: {
            detail
                .toolbar {
                    if selection != .chat {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { chatPanel.toggle() } label: { Image(systemName: "envelope") }
                                .accessibilityLabel("Main chat")
                                .keyboardShortcut("j", modifiers: .command)
                        }
                    }
                }
                .inspector(isPresented: $chatPanel) {
                    MainChatView(title: "Chat")
                        .inspectorColumnWidth(min: 320, ideal: 380, max: 480)
                }
        }
        #if DEBUG
        // Screenshots of the slide-over chat: -openChatPanel YES.
        .task { if UserDefaults.standard.bool(forKey: "openChatPanel") { chatPanel = true } }
        #endif
        // A notification or the debug tab picks the matching sidebar row.
        .onChange(of: tab, initial: true) { _, tab in
            switch tab {
            case .projects: if case .project = selection {} else { selection = .projects }
            case .needs: selection = .needs
            case .chat: selection = .chat
            case .settings: selection = .settings
            }
        }
        .onChange(of: selection) { _, item in
            switch item {
            case .needs: tab = .needs
            case .chat: tab = .chat; chatPanel = false
            case .settings: tab = .settings
            default: tab = .projects
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .needs:
            NeedsYouView(openDecision: $openNeeds)
        case .chat:
            MainChatView(openBot: $openBot)
        case .settings:
            SettingsView(inTab: true)
        case .project(let link):
            if let computer = fleet.computer(id: link.computerId) {
                NavigationStack {
                    ProjectScreen(projectId: link.projectId)
                        .computerEnvironment(computer)
                        .needsDestinations()
                }
                .id(link)
            }
        case .projects, nil:
            ProjectsHomeView(open: { selection = .project($0) })
        }
    }
}
