import SwiftUI

struct InboxView: View {
    @Environment(PRPoller.self) private var poller
    @Environment(ActionQueue.self) private var actionQueue
    let onSelect: (InboxPR) -> Void

    private var inboxPRs: [InboxPR] {
        poller.prs
            .filter { $0.role == .reviewRequested || $0.role == .both }
            .sorted(by: Self.priority)
    }

    var body: some View {
        PRListView(
            prs: inboxPRs,
            emptyText: "No reviews requested.",
            isFetching: poller.isFetching,
            lastError: poller.lastError,
            refreshingPRs: poller.refreshingPRs,
            onRefreshPR: { poller.refreshPR($0) },
            onMergePR: { pr, method in actionQueue.enqueue(pr, kind: .merge(method: method)) },
            onSelect: onSelect
        )
    }

    /// Sort: not-yet-reviewed first, then changes-requested, drafts last.
    private static func priority(_ a: InboxPR, _ b: InboxPR) -> Bool {
        bucket(a) < bucket(b)
    }

    private static func bucket(_ pr: InboxPR) -> Int {
        if pr.isDraft { return 9 }
        switch pr.reviewDecision {
        case "REVIEW_REQUIRED": return 0  // I haven't reviewed yet
        case "CHANGES_REQUESTED": return 2
        case "APPROVED": return 8         // already approved by me/others
        default: return 5
        }
    }
}
