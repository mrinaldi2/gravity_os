import SwiftUI

/// A bot's tool waiting on the owner: what it wants to run, when it is denied
/// if nobody answers, its input on demand, and the three answers.
struct PermissionCard: View {
    @Environment(AppStore.self) private var store
    let request: PermissionRequest
    /// Tapping the bot's name opens it; nil where its screen is already open.
    var openBot: ((String) -> Void)?
    @State private var showInput = false
    @State private var reason = ""
    @State private var busy: PermissionRequest.Answer?
    @State private var failure: String?

    private var bot: Bot? { store.bot(request.botId) }
    private var name: String { bot?.name ?? "A bot" }
    private var canAnswer: Bool { store.canControl && store.status == .connected && busy == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                if let openBot {
                    Button { openBot(request.botId) } label: {
                        Text(name).font(.subheadline.weight(.semibold)).underline()
                    }
                    .buttonStyle(.borderless)
                    .tint(.primary)
                } else {
                    Text(name).font(.subheadline.weight(.semibold))
                }
                Text("wants to run").font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text(request.summary)
                .font(.callout.monospaced())
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let expires = request.expiresAt {
                Text("Denied at \(expires.formatted(date: .omitted, time: .shortened)) if unanswered")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !request.input.isEmpty {
                DisclosureGroup(isExpanded: $showInput) {
                    Text(request.input)
                        .font(.system(size: 11, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } label: {
                    Text("Input").font(.caption.weight(.semibold))
                }
                .tint(.secondary)
            }
            TextField("Reason, sent with Deny (optional)", text: $reason, axis: .vertical)
                .font(.footnote)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .disabled(!store.canControl)
            HStack(spacing: 8) {
                answerButton(.allowOnce, prominent: true)
                answerButton(.allowSession, prominent: false)
                answerButton(.deny, prominent: false)
            }
            if !store.canControl {
                Text("This device can read but not answer: it needs the control grant.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(Color.errorText)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.orange.opacity(0.35)))
        .accessibilityElement(children: .contain)
    }

    private func answerButton(_ answer: PermissionRequest.Answer, prominent: Bool) -> some View {
        Button {
            send(answer)
        } label: {
            Group {
                if busy == answer {
                    ProgressView().controlSize(.small)
                } else {
                    Text(answer == .allowSession ? "For session" : answer.label)
                }
            }
            .font(.footnote.weight(.semibold))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(answer == .deny ? .red : prominent ? .green : .accentColor)
        .disabled(!canAnswer)
        .accessibilityLabel(answer.label)
    }

    private func send(_ answer: PermissionRequest.Answer) {
        busy = answer
        failure = nil
        Task {
            do {
                try await store.answerPermission(request, answer, reason: reason.trimmingCharacters(in: .whitespacesAndNewlines))
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                failure = error.localizedDescription
            }
            busy = nil
        }
    }
}
