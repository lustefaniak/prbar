import Foundation

/// Whether a review-requested PR gets an AI review on its own, decided
/// from values alone: the PR, its resolved repo config, and the review
/// state this instance already holds for it. The "select" stage of the
/// review pipeline, kept free of the worker so the app, the CLI and
/// tests all apply the same gates in the same order.
enum ReviewAdmission {
    enum Decision: Sendable, Hashable {
        /// Hand it to `ReviewQueueWorker.enqueue`.
        case review
        /// A deliberate skip, recorded as review state so the UI can say why.
        case skip(ReviewState.SkipReason)
        /// Not a candidate at all; nothing is recorded.
        case ignore(IgnoreReason)
    }

    enum IgnoreReason: String, Sendable, Hashable {
        /// The viewer isn't (or is no longer) a requested reviewer.
        case notRequested
        /// A review already failed at this head SHA. Failures are terminal
        /// per SHA: a re-run on every poll would burn cost re-failing
        /// deterministically, or flip the row back to "Reviewing…" and
        /// hide the failure. A new commit re-arms; manual Re-run forces.
        case failedAtCurrentSha
    }

    /// Gates in order. The order decides which reason a skipped PR shows,
    /// so the more specific repo-config reasons come first and the
    /// verdict-marker check comes last.
    static func evaluate(
        pr: InboxPR,
        config: ResolvedRepoConfig,
        existing: ReviewState?
    ) -> Decision {
        guard pr.role == .reviewRequested || pr.role == .both else {
            return .ignore(.notRequested)
        }
        // Also a poller filter, but the poller is not the only entry
        // point: the CLI is handed a PR directly and never polls.
        if TitleExclusion.isExcluded(title: pr.title, patterns: config.excludeTitlePatterns) {
            return .skip(.titleExcluded)
        }
        // Repo opted out of AI triage entirely → ReadinessCoordinator
        // marks these as "ready" immediately on the human side.
        if !config.aiReviewEnabled {
            return .skip(.aiReviewDisabled)
        }
        // Drafts churn a lot and reviewing them burns cost on
        // intermediate state.
        if pr.isDraft && !config.reviewDrafts {
            return .skip(.draftNotReviewed)
        }
        // Another human already reviewed, so it's covered. Inbox
        // visibility is governed separately by the opt-in hide filter
        // (same predicate); manual Re-run still works regardless.
        if config.skipAIIfReviewedByOthers && pr.isReviewedByOthers {
            return .skip(.reviewedByOthers)
        }
        if let existing, case .failed = existing.status, existing.headSha == pr.headSha {
            return .ignore(.failedAtCurrentSha)
        }
        // Some PRBar already posted an AI verdict for this exact commit,
        // most often another requested reviewer's instance. Deferred to a
        // completed review this instance holds for the same head: that's
        // the verdict the UI shows, and `enqueue`'s cache-hit path must
        // stay reachable to fire the settled pulse `ReadinessCoordinator`
        // needs after a relaunch.
        if pr.hasPRBarVerdictAtHead, !holdsCompletedReview(existing, at: pr.headSha) {
            return .skip(.reviewedByPRBarElsewhere)
        }
        return .review
    }

    private static func holdsCompletedReview(_ existing: ReviewState?, at headSha: String) -> Bool {
        guard let existing, existing.headSha == headSha, case .completed = existing.status else {
            return false
        }
        return true
    }
}
