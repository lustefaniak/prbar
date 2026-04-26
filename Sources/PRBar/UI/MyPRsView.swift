import SwiftUI

struct MyPRsView: View {
    @Environment(PRPoller.self) private var poller

    private var myPRs: [InboxPR] {
        poller.prs
            .filter { $0.role == .authored || $0.role == .both }
            .sorted(by: Self.priority)
    }

    var body: some View {
        PRListView(
            prs: myPRs,
            emptyText: "No PRs you authored.",
            isFetching: poller.isFetching,
            lastError: poller.lastError,
            refreshingPRs: poller.refreshingPRs,
            onRefreshPR: { poller.refreshPR($0) }
        )
    }

    /// Sort: ready-to-merge first, then has-comments, conflicting, failing,
    /// in-flight, drafts at the bottom.
    private static func priority(_ a: InboxPR, _ b: InboxPR) -> Bool {
        bucket(a) < bucket(b)
    }

    private static func bucket(_ pr: InboxPR) -> Int {
        if pr.isDraft { return 9 }
        switch pr.mergeStateStatus {
        case "CLEAN" where pr.reviewDecision == "APPROVED":
            return 0   // ready to merge
        case "BLOCKED" where pr.reviewDecision == "APPROVED":
            return 1   // approved but waiting on something (CI?)
        case "DIRTY", "CONFLICTING":
            return 5   // conflicts — needs rebase
        default: break
        }
        switch pr.checkRollupState {
        case "FAILURE", "ERROR":
            return 4   // CI failing — needs attention
        case "PENDING", "EXPECTED":
            return 6   // CI in flight
        default: break
        }
        if pr.reviewDecision == "CHANGES_REQUESTED" { return 3 }
        if pr.reviewDecision == "REVIEW_REQUIRED"  { return 7 }
        return 8
    }
}
