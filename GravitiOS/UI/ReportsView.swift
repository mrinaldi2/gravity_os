import SwiftUI

/// The shared artifacts folder: the reports the bots write for each other and for you.
struct ReportsView: View {
    @Environment(AppStore.self) private var store
    @Environment(LensStore.self) private var lens
    @State private var query = ""
    @State private var count = Page.size

    private var matching: [LensArtifact] {
        guard !query.isEmpty else { return lens.artifacts }
        return lens.artifacts.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    /// The newest reports; searching looks through all of them.
    private var shown: [LensArtifact] { Array(matching.prefix(count)) }

    var body: some View {
        NavigationStack {
            List {
                ForEach(shown) { artifact in
                    NavigationLink(value: artifact) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(artifact.title).font(.subheadline.weight(.medium)).lineLimit(2)
                            HStack(spacing: 6) {
                                // From the daemon, artifacts name their project by id.
                                Text(store.projects.first { $0.id == artifact.project }?.name ?? artifact.project)
                                if let modified = artifact.modified { Text("·"); Text(modified.relative) }
                                Text("·")
                                Text(ByteCountFormatter.string(fromByteCount: Int64(artifact.size), countStyle: .file))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                if matching.count > count {
                    ShowMoreButton { count += Page.size }
                }
            }
            .overlay { if lens.artifacts.isEmpty { LensEmptyState() } }
            .searchable(text: $query, prompt: "Search reports")
            .refreshable { await lens.loadArtifacts() }
            .task(id: store.projects.count) { await lens.loadArtifacts() }
            .navigationTitle("Reports")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { ComputerSwitcher() } }
            .navigationDestination(for: LensArtifact.self) { ReportView(artifact: $0) }
        }
    }
}

struct ReportView: View {
    @Environment(LensStore.self) private var lens
    let artifact: LensArtifact
    @State private var text: String?
    @State private var error: String?

    var body: some View {
        ScrollView {
            Group {
                if let text {
                    if artifact.name.hasSuffix(".md") || artifact.name.hasSuffix(".markdown") {
                        MarkdownText(text, report: (artifact.project, artifact.name))
                    } else {
                        Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }
                } else if let error {
                    Text(error).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(artifact.title == artifact.name ? "Report" : artifact.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if let text {
                ShareLink(item: text, subject: Text(artifact.title)) { Image(systemName: "square.and.arrow.up") }
            }
        }
        .task {
            do { text = try await lens.artifact(project: artifact.project, name: artifact.name) } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
