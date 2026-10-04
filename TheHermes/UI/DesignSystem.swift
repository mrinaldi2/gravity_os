import SwiftUI

// "Gravity Night": the one look every list in the app shares. Every list is
// an inset grouped card; every row has a leading avatar, tile or dot, one
// title, at most two lines under it, and one trailing element; status is a
// dot and a word; a badge is a tinted capsule; long lists load their next
// page as their end comes into view.

/// What a colour means, wherever it appears.
enum Tone {
    case ready, working, needsYou, failed, quiet, worker

    var color: Color {
        switch self {
        case .ready: .green
        case .working: .accentColor
        case .needsYou: .orange
        case .failed: .red
        case .quiet: .secondary
        case .worker: .teal
        }
    }
}

extension BotState {
    var tone: Tone {
        switch self {
        case .working: .working
        case .ready: .ready
        case .waitingForUser, .waitingForApproval, .rateLimited: .needsYou
        case .authFailed, .crashed: .failed
        case .starting, .stopping, .stopped, .unknown: .quiet
        }
    }
}

struct StatusDot: View {
    let tone: Tone
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(tone.color).frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// A dot and a word: the status of a bot, a command, a computer.
struct StatusLabel: View {
    let text: String
    let tone: Tone
    /// A spinner instead of the dot, for something under way.
    var busy = false

    var body: some View {
        HStack(spacing: 5) {
            if busy {
                ProgressView().controlSize(.mini)
            } else {
                StatusDot(tone: tone)
            }
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(tone == .needsYou || tone == .failed ? tone.color : .secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The one badge: a word in a tinted capsule.
struct Pill: View {
    let text: String
    var tone: Tone = .quiet

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(tone.color)
            .background(tone.color.opacity(0.16), in: Capsule())
    }
}

/// An SF Symbol on a rounded square, leading a row about a thing (a file,
/// a command, a computer) rather than a bot.
struct IconTile: View {
    let systemImage: String
    var tone: Tone? = nil
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(tone.map { $0.color.opacity(0.18) } ?? Color(.tertiarySystemFill))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.48, weight: .medium))
                    .foregroundStyle(tone?.color ?? .secondary)
            }
            .accessibilityHidden(true)
    }
}

/// The row every list uses: leading, a title, up to two lines under it, trailing.
struct ItemRow<Leading: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    var detail: String?
    var monoSubtitle = false
    var titleLines = 1
    var subtitleLines = 1
    var titleTone: Tone?
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            leading()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(titleTone?.color ?? .primary)
                    .lineLimit(titleLines)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(monoSubtitle ? .caption.monospaced() : .footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(subtitleLines)
                }
                if let detail, !detail.isEmpty {
                    Text(detail).font(.footnote).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            trailing()
        }
        .padding(.vertical, 5)
        .frame(minHeight: 44)
    }
}

extension ItemRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, detail: String? = nil, monoSubtitle: Bool = false,
         titleLines: Int = 1, subtitleLines: Int = 1, titleTone: Tone? = nil,
         @ViewBuilder leading: @escaping () -> Leading) {
        self.init(title: title, subtitle: subtitle, detail: detail, monoSubtitle: monoSubtitle,
                  titleLines: titleLines, subtitleLines: subtitleLines, titleTone: titleTone,
                  leading: leading, trailing: { EmptyView() })
    }
}

/// A section's title with how many it holds.
struct SectionTitle: View {
    let text: String
    var count: Int?

    init(_ text: String, count: Int? = nil) {
        self.text = text
        self.count = count
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
            if let count { Text("\(count)").foregroundStyle(.secondary) }
        }
    }
}

/// A list with nothing in it yet, said once, the same way everywhere.
struct EmptyNote: View {
    let text: String
    var systemImage = "tray"

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
    }
}

/// The last row of a list that loads a page at a time. It loads the next page
/// as it comes into view, says so quietly, offers Try again when that fails,
/// and once everything is in says how many there are.
struct ListEnd: View {
    let hasMore: Bool
    /// What the list holds, plural: "commands".
    let noun: String
    /// How many are loaded, so the next page starts once the last one lands.
    let loaded: Int
    let load: () async throws -> Void
    @State private var failed = false
    @State private var trying = 0

    var body: some View {
        if hasMore {
            Group {
                if failed {
                    HStack {
                        Text("Couldn’t load earlier \(noun)").foregroundStyle(.orange)
                        Spacer()
                        Button("Try again") { failed = false; trying += 1 }.fontWeight(.semibold)
                    }
                } else {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Loading earlier \(noun)…").foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .font(.subheadline)
            .frame(minHeight: 36)
            // Runs when the row scrolls into view, again after each page.
            .task(id: "\(loaded)-\(trying)") {
                guard !failed else { return }
                do { try await load() } catch { failed = true }
            }
        } else if loaded > Page.size {
            Text("All \(loaded) \(noun)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }
}

/// The computer a view belongs to, with everything its views read.
extension View {
    func computerEnvironment(_ computer: Computer) -> some View {
        environment(computer)
            .environment(computer.store)
            .environment(computer.lens)
            .environment(computer.screen)
    }
}
