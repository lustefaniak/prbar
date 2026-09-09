import Foundation

/// Picks the PR sequential focus mode should land on next.
///
/// Pure so the "don't hand the user a PR they already actioned" rule is
/// testable. `poller.prs` is a snapshot that lags a posted review by a
/// poll cycle, so the PR's GitHub state can't answer that question — the
/// caller's `handled` set does.
enum ReviewAdvance {
    /// First PR in `prs` that still needs the user: review is requested
    /// of them, it isn't a draft, no other human has decided it, the
    /// caller hasn't handled it in this run, and AI triage isn't still
    /// working on it.
    ///
    /// `handled` is recorded when a review is *submitted*. A write that
    /// errors does not put the PR back in rotation: `ActionQueue` retries
    /// it with backoff, and a verdict the user already gave is theirs to
    /// re-send from the failed-action UI, not to be asked for again.
    static func next(
        in prs: [InboxPR],
        handled: Set<String>,
        triageStatus: (String) -> ReviewState.Status?
    ) -> InboxPR? {
        prs.first { pr in
            guard !handled.contains(pr.nodeId) else { return false }
            guard pr.role == .reviewRequested || pr.role == .both else { return false }
            guard !pr.isDraft else { return false }
            // Skip ones another reviewer decided (approved or requested
            // changes) — same predicate as the Inbox hide filter.
            if pr.isReviewedByOthers { return false }
            // Treat "no review state" as ready too — repos with AI off
            // never enqueue, so they'd otherwise be skipped here.
            switch triageStatus(pr.nodeId) {
            // .skipped = AI won't triage it (e.g. repo AI off), so the human
            // still needs to look — treat it as ready like terminal states.
            case .none, .completed, .failed, .skipped: return true
            case .queued, .running: return false
            }
        }
    }
}
