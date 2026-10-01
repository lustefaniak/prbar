import Foundation

/// Opt-in control for whether review-requested PRs that another reviewer has
/// already weighed in on stay visible in the Inbox list.
///
/// When you submit a review GitHub drops you from the PR's requested-reviewers,
/// so a PR you reviewed leaves the Inbox on its own. The rows this filter
/// catches are therefore ones *someone else* approved or requested changes on
/// while you're still an outstanding requested reviewer. Hidden by an opt-in so
/// the default keeps surfacing everything you've been asked to look at.
enum InboxVisibility {
    /// Default off (unset key reads false): hiding rows is a deliberate
    /// opt-in. Views read this via `@AppStorage`.
    static let hideReviewedByOthersKey = "hideReviewedByOthersFromInbox"

    /// Apply the opt-in filter to an already role-filtered inbox list.
    /// `InboxPR.isReviewedByOthers` is the shared definition — the AI
    /// auto-enqueue skip reads the same property.
    static func filter(_ prs: [InboxPR], hideReviewedByOthers: Bool) -> [InboxPR] {
        guard hideReviewedByOthers else { return prs }
        return prs.filter { !$0.isReviewedByOthers }
    }
}
