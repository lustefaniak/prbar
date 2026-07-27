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
        let pushingBack = staged.count - approving

        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: pushingBack > 0 ? "exclamationmark.bubble.fill" : "checkmark.seal.fill")
                .foregroundStyle(pushingBack > 0 ? .orange : .green)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(headline(approving: approving, pushingBack: pushingBack)) in \(secondsLeft)s")
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
            (pushingBack > 0 ? Color.orange : Color.green).opacity(0.10),
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    private func headline(approving: Int, pushingBack: Int) -> String {
        if pushingBack == 0 {
            return "Auto-approving \(approving) PR\(approving == 1 ? "" : "s")"
        }
        if approving == 0 {
            return "Posting changes requested on \(pushingBack) PR\(pushingBack == 1 ? "" : "s")"
        }
        return "Auto-approving \(approving), pushing back on \(pushingBack)"
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
