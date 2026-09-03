import SwiftUI

/// Single batched banner shown in `PopoverView` for everything the
/// auto-review policy decided. Deliberately *one* banner for the whole
/// batch — design goal is "one context switch per cycle, not one per PR."
///
/// Two independent parts:
/// - **Staged posts** (approve / comment / request changes) with the undo
///   countdown. Appears only after every in-flight review settles.
/// - **Flagged denials** (`AutoDenyAction.flagOnly`) — informational, never
///   posted, dismissed by hand.
struct AutoReviewBanner: View {
    @Environment(ReviewQueueWorker.self) private var queue

    @State private var now: Date = Date()
    @State private var ticker: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if queue.batchUndoActive {
                stagedRow(Array(queue.pendingAutoActions.values))
            }
            if !queue.flaggedDenials.isEmpty {
                flaggedRow(Array(queue.flaggedDenials.values))
            }
        }
        .onAppear { startTicker() }
        .onDisappear { stopTicker() }
    }

    // MARK: - staged posts

    @ViewBuilder
    private func stagedRow(_ staged: [ReviewQueueWorker.StagedAutoReview]) -> some View {
        let secondsLeft = max(0, Int((queue.batchUndoDeadline ?? now).timeIntervalSince(now)))
        let approving = staged.filter { $0.action == .approve }.count
        let commenting = staged.filter { $0.action == .comment }.count
        let pushingBack = staged.filter { $0.action == .requestChanges }.count

        // Tone follows the strongest verdict in the batch. A comment-only
        // batch is usually shared findings, which casts no verdict at all —
        // the green approval seal would say the opposite of what happened.
        let tone: (icon: String, color: Color) = {
            if pushingBack > 0 { return ("exclamationmark.bubble.fill", .orange) }
            if approving > 0 { return ("checkmark.seal.fill", .green) }
            return ("text.bubble.fill", .blue)
        }()

        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: tone.icon)
                .foregroundStyle(tone.color)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(headline(approving: approving, commenting: commenting, pushingBack: pushingBack)) in \(secondsLeft)s")
                    .font(.caption.bold())
                Text(summary(staged))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            Spacer()

            Button("Undo") { queue.cancelAutoReviewBatch() }
                .keyboardShortcut("z", modifiers: .command)
            Button("Post now") { queue.fireAutoReviewBatchNow() }
                .buttonStyle(.borderedProminent)
        }
        .padding(8)
        .background(
            tone.color.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    /// A comment post carries no verdict, so it can't be folded in with
    /// "changes requested" — most of them are shared findings sent ahead
    /// of a human review that hasn't happened yet.
    private func headline(approving: Int, commenting: Int, pushingBack: Int) -> String {
        var parts: [String] = []
        if approving > 0 { parts.append("approving \(approving)") }
        if commenting > 0 { parts.append("commenting on \(commenting)") }
        if pushingBack > 0 { parts.append("requesting changes on \(pushingBack)") }
        let total = approving + commenting + pushingBack
        guard !parts.isEmpty else { return "Posting \(total) review\(total == 1 ? "" : "s")" }
        return "Auto-" + parts.joined(separator: ", ")
    }

    // MARK: - flag-only denials

    @ViewBuilder
    private func flaggedRow(_ flagged: [ReviewQueueWorker.StagedAutoReview]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "flag.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("AI wants changes on \(flagged.count) PR\(flagged.count == 1 ? "" : "s")")
                    .font(.caption.bold())
                Text("Nothing posted — open the PR to review and send it yourself.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(summary(flagged))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            Spacer()

            Button("Dismiss") { queue.dismissAllFlaggedDenials() }
        }
        .padding(8)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }

    private func summary(_ entries: [ReviewQueueWorker.StagedAutoReview]) -> String {
        entries.map { "\($0.pr.nameWithOwner)#\($0.pr.number)" }
            .joined(separator: ", ")
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            now = Date()
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}
