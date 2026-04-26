import SwiftUI

/// Single batched undo banner shown in `PopoverView` when one or more
/// staged auto-approvals are about to fire. Deliberately *one* banner
/// for the whole batch — design goal is "one context switch per cycle,
/// not one per PR." Triggers only after every in-flight review settles.
struct AutoApproveBanner: View {
    @Environment(ReviewQueueWorker.self) private var queue

    @State private var now: Date = Date()
    @State private var ticker: Timer?

    var body: some View {
        let staged = Array(queue.pendingAutoApprovals.values)
        let secondsLeft = max(0, Int((queue.batchUndoDeadline ?? now).timeIntervalSince(now)))

        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text("Auto-approving \(staged.count) PR\(staged.count == 1 ? "" : "s") in \(secondsLeft)s")
                    .font(.caption.bold())
                Text(stagedSummary(staged))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            Spacer()

            Button("Undo") { queue.cancelAutoApproveBatch() }
                .keyboardShortcut("z", modifiers: .command)
            Button("Approve now") { queue.approveBatchNow() }
                .buttonStyle(.borderedProminent)
        }
        .padding(8)
        .background(.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        .onAppear { startTicker() }
        .onDisappear { stopTicker() }
    }

    private func stagedSummary(_ staged: [ReviewQueueWorker.PendingAutoApprove]) -> String {
        staged.map { "\($0.pr.nameWithOwner)#\($0.pr.number)" }
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
