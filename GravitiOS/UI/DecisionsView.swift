import SwiftUI

/// The Control Center: what the bots are waiting on the owner to rule on.
struct DecisionsView: View {
    @Environment(AppStore.self) private var store
    @Binding var openDecision: String?
    @State private var path: [String] = []

    private var pending: [Decision] {
        store.decisions.filter(\.pending).sorted { lhs, rhs in
            if lhs.urgent != rhs.urgent { return lhs.urgent }
            return (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast)
        }
    }

    private var held: [Decision] { store.decisions.filter { $0.state == "held" } }

    private var closed: [Decision] {
        Array(store.decisions.filter { $0.state == "settled" || $0.state == "withdrawn" }.prefix(40))
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                section("Waiting on you", pending)
                section("On hold", held)
                section("Settled", closed)
            }
            .listStyle(.insetGrouped)
            .overlay {
                if store.decisions.isEmpty {
                    ContentUnavailableView("Nothing to decide", systemImage: "checkmark.circle",
                                           description: Text("Bots raise decisions here when they need your ruling."))
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { ConnectionBanner() }
            .refreshable { await store.refreshDecisions() }
            .navigationTitle("Decisions")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { ComputerSwitcher() } }
            .navigationDestination(for: String.self) { DecisionDetailView(decisionId: $0) }
        }
        .onChange(of: openDecision) { _, id in
            guard let id else { return }
            path = [id]
            openDecision = nil
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ decisions: [Decision]) -> some View {
        if !decisions.isEmpty {
            Section(title) {
                ForEach(decisions) { decision in
                    NavigationLink(value: decision.id) { DecisionRow(decision: decision) }
                }
            }
        }
    }
}

private struct DecisionRow: View {
    @Environment(AppStore.self) private var store
    let decision: Decision

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(avatar: decision.raisedByAvatar, name: decision.raisedByName, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(decision.title).font(.headline).lineLimit(3)
                HStack(spacing: 6) {
                    Text(decision.raisedByName)
                    Text("·")
                    Text(store.projectName(decision.projectId))
                    if let at = decision.createdAt {
                        Text("·")
                        Text(at.relative)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                HStack(spacing: 6) {
                    if decision.urgent { Chip(text: "Urgent", color: .red) }
                    if decision.state == "answered" { Chip(text: "Draft answer", color: .blue) }
                    if decision.state == "withdrawn" { Chip(text: "Withdrawn", color: .gray) }
                    if let deadline = decision.deadlineAt, decision.pending {
                        Chip(text: "Due \(deadline.relative)", color: .orange)
                    }
                    ForEach(decision.tags.prefix(2), id: \.self) { Chip(text: $0, color: .secondary) }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct Chip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }
}
