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
        /// A decide rule depends on facts not fetched yet; fetch them and
        /// plan again.
        case needs(Set<LazyFact>)
    }

    static func plan(
        pr: InboxPR,
        review: AggregatedReview,
        config: ResolvedRepoConfig,
        providerId: ProviderID,
        diffText: String,
        prior: [PriorReview] = [],
        lazy: LazyFactValues = LazyFactValues(),
        now: Date = Date(),
        onRule: ((DecideFacts, RuleDecision?) -> Void)? = nil
    ) -> Outcome {
        let settings = AutoReviewPolicy.evaluate(pr: pr, review: review, providerId: providerId, config: config)
        if let rules = config.rules, !rules.decide.isEmpty || rules.failure != nil {
            let facts = decideFacts(pr: pr, review: review, providerId: providerId, diffText: diffText,
                                    prior: prior, lazy: lazy, rules: rules, now: now, below: .settings(settings))
            // The diff is in hand, so the files are never pending here.
            do {
                switch try rules.decide(facts, pending: lazy.pending.subtracting([.files])) {
                case .needs(let needed):
                    return .needs(needed)
                case .decided(let decision?):
                    onRule?(facts, decision)
                    return plan(decision, pr: pr, review: review, diffText: diffText, now: now)
                case .decided(nil):
                    onRule?(facts, nil)
                }
            } catch {
                // Posting nothing is the side that can't go wrong in public.
                PRBarLog.triage.error("decide rule failed pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public): \(String(describing: error), privacy: .public)")
                return .none(reason: "a decide rule failed, nothing posted: \(error)")
            }
        }
        switch settings {
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

    static func decideFacts(
        pr: InboxPR, review: AggregatedReview, providerId: ProviderID, diffText: String,
        prior: [PriorReview], lazy: LazyFactValues, rules: Rules, now: Date, below: BelowFacts? = nil
    ) -> DecideFacts {
        DecideFacts(
            pr: ChangeFacts(pr, now: now, files: FileFacts.list(diff: diffText), committers: lazy.committers),
            review: ReviewFacts(review, provider: providerId, prior: prior),
            viewer: pr.viewerLogin, lists: rules.lists, now: now, below: below)
    }

    /// What a decide rule asked for, made concrete.
    static func plan(
        _ decision: RuleDecision, pr: InboxPR, review: AggregatedReview, diffText: String, now: Date
    ) -> Outcome {
        let rule = "rule \(decision.rule)"
        func findings(defaultInline: Bool, defaultCap: Int) -> [DiffAnnotation] {
            guard decision.inline ?? defaultInline else { return [] }
            let floor = decision.minSeverity ?? .info
            let kept = review.annotations.filter { $0.severity >= floor }.sorted { $0.severity > $1.severity }
            let cap = decision.maxComments ?? defaultCap
            return cap > 0 ? Array(kept.prefix(cap)) : kept
        }
        func summaryBody() -> String {
            review.summaryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? denyFallbackBody(review) : review.summaryMarkdown
        }
        func staged(_ action: ReviewActionKind?, body: String, comments: [GHClient.InlineComment], source: ActionSource = .automated)
            -> ReviewQueueWorker.StagedAutoReview
        {
            .init(pr: pr, review: review, action: action, body: body, comments: comments, stagedAt: now, source: source)
        }

        switch decision.action {
        case .none:
            return .none(reason: "\(rule): post nothing")
        case .approve:
            let comments = inlineComments(findings(defaultInline: false, defaultCap: 0), diffText: diffText)
            return .post(staged(.approve, body: decision.attribution == true ? attributionBody(review) : "", comments: comments))
        case .requestChanges, .flag:
            let comments = inlineComments(findings(defaultInline: true, defaultCap: 0), diffText: diffText)
            // A flag is never posted, so it carries no GitHub action.
            let isFlag = decision.action == .flag
            let post = staged(isFlag ? nil : .requestChanges, body: summaryBody(), comments: comments)
            return isFlag ? .flag(post) : .post(post)
        case .comment:
            let comments = inlineComments(findings(defaultInline: true, defaultCap: 0), diffText: diffText)
            return .post(staged(.comment, body: summaryBody(), comments: comments))
        case .share:
            // A share is the findings; with none at the floor there is
            // nothing to give the author, and a summary alone would make
            // PRBar comment on every PR it looks at.
            let shared = findings(defaultInline: true, defaultCap: 20)
            guard !shared.isEmpty else { return .none(reason: "\(rule): no findings to share") }
            let comments = inlineComments(shared, diffText: diffText)
            return .post(staged(.comment, body: comments.isEmpty ? shareBody(review) : "", comments: comments, source: .sharedFindings))
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
