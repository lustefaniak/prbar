import Foundation

/// Turns a completed review into what PRBar would post on its own: the
/// `AutoReviewPolicy` decision made concrete as a GitHub review action,
/// a body and inline comments. Pure — the worker owns the undo window,
/// the staging state and the actual write.
///
/// Body and comments are resolved here, at staging time, because this is
/// the last point the run's diff is in hand; the post fires after the
/// undo window and has none.
enum AutoReviewPlan {
    enum Outcome: Sendable, Hashable {
        /// Nothing to post. `reason` is for the log.
        case none(reason: String)
        /// Stage behind the undo window, then post.
        case post(ReviewQueueWorker.StagedAutoReview)
        /// `autoDeny.action == .flagOnly`: surface in PRBar, post nothing.
        case flag(ReviewQueueWorker.StagedAutoReview)
    }

    static func plan(
        pr: InboxPR,
        review: AggregatedReview,
        config: ResolvedRepoConfig,
        providerId: ProviderID,
        diffText: String,
        now: Date = Date()
    ) -> Outcome {
        switch AutoReviewPolicy.evaluate(pr: pr, review: review, providerId: providerId, config: config) {
        case .skip(let reason):
            return .none(reason: reason)

        case .approve:
            let cfg = config.autoApprove
            return .post(.init(
                pr: pr,
                review: review,
                action: .approve,
                // Empty body = a bare GitHub approval, which is what the
                // green check already says. The attribution line is opt-in
                // because it lands as a comment on every PR the bot touches.
                body: cfg.postAttributionComment ? attributionBody(review) : "",
                comments: cfg.postInlineAnnotations
                    ? inlineComments(review.annotations, diffText: diffText)
                    : [],
                stagedAt: now
            ))

        case .share:
            // Only the annotations the policy actually asked for — sharing
            // "warnings and blockers" while posting every nitpick inline
            // would contradict the setting the user chose.
            let floor = config.shareFindings.minSeverity ?? .info
            // Severity first, then the cap — so a truncated share keeps the
            // findings that matter most rather than whichever the model
            // happened to emit first.
            var shared = review.annotations
                .filter { $0.severity >= floor }
                .sorted { $0.severity > $1.severity }
            let cap = config.shareMaxComments
            if cap > 0 && shared.count > cap {
                PRBarLog.triage.notice("share capped pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public) found=\(shared.count, privacy: .public) cap=\(cap, privacy: .public)")
                shared = Array(shared.prefix(cap))
            }
            let comments = inlineComments(shared, diffText: diffText)
            return .post(.init(
                pr: pr,
                review: review,
                action: .comment,
                // Findings that landed inline are the whole review — a body
                // on top of them can only restate the diff back to the
                // author. GitHub accepts an empty body on a COMMENT review
                // that carries inline comments; it rejects one that carries
                // none, so the summary stays as the body in that case, where
                // dropping it would post nothing at all.
                body: comments.isEmpty ? shareBody(review) : "",
                comments: comments,
                stagedAt: now,
                source: .sharedFindings
            ))

        case .deny(let denyAction):
            let cfg = config.autoDeny
            let staged = ReviewQueueWorker.StagedAutoReview(
                pr: pr,
                review: review,
                action: denyAction.reviewActionKind,
                // GitHub rejects an empty body on REQUEST_CHANGES and
                // COMMENT, so the AI summary is the body — falling back to
                // the attribution line only if the summary came back blank.
                body: review.summaryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? denyFallbackBody(review)
                    : review.summaryMarkdown,
                comments: cfg.postInlineAnnotations
                    ? inlineComments(review.annotations, diffText: diffText)
                    : [],
                stagedAt: now
            )
            return denyAction == .flagOnly ? .flag(staged) : .post(staged)
        }
    }

    private static func inlineComments(
        _ annotations: [DiffAnnotation],
        diffText: String
    ) -> [GHClient.InlineComment] {
        guard !annotations.isEmpty else { return [] }
        return InlineCommentMapper.map(annotations: annotations, hunks: DiffParser.parse(diffText))
    }

    /// The share's body when nothing anchored inline. No banner or
    /// disclaimer: a shared review should be indistinguishable from any
    /// other review PRBar posts. GitHub rejects an empty body on COMMENT,
    /// hence the fallback.
    static func shareBody(_ review: AggregatedReview) -> String {
        let summary = review.summaryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty
            ? "PRBar's AI review flagged the findings below (\(formatConfidence(review.confidence)) confidence) but returned no summary."
            : summary
    }

    static func attributionBody(_ review: AggregatedReview) -> String {
        "Auto-approved by PRBar (\(formatConfidence(review.confidence)) confidence)."
    }

    static func denyFallbackBody(_ review: AggregatedReview) -> String {
        "PRBar's AI review requested changes (\(formatConfidence(review.confidence)) confidence) but returned no summary. See the annotations."
    }

    private static func formatConfidence(_ c: Double) -> String {
        String(format: "%.0f%%", c * 100)
    }
}
