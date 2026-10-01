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
        /// A select rule's outcome depends on facts not fetched yet. Fetch
        /// them and ask again; nothing is recorded meanwhile.
        case needs(Set<LazyFact>)
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
    /// `requireRequested: false` applies every gate to a PR the viewer
    /// wasn't asked to review, as when a coding agent asks for a review of
    /// the PR it is working on.
    static func evaluate(
        pr: InboxPR,
        config: ResolvedRepoConfig,
        existing: ReviewState?,
        requireRequested: Bool = true,
        trigger: RuleTrigger = .reviewRequested,
        lazy: LazyFactValues = LazyFactValues(),
        now: Date = Date(),
        onRule: ((RuleLayer, SelectFacts, RuleSelection?) -> Void)? = nil
    ) -> Decision {
        guard !requireRequested || pr.role == .reviewRequested || pr.role == .both else {
            return .ignore(.notRequested)
        }
        // A select rule decides before the repo settings. Its `review`
        // still yields to a failure at this commit and to a verdict some
        // PRBar already posted for it: those save repeating a run, they
        // aren't a policy a rule should have to restate.
        let settings = settingsSkip(pr: pr, config: config)
        let below = settings.map { BelowFacts.settings("skip", reason: $0.detail) } ?? .settings("review")
        switch selectRule(pr: pr, config: config, trigger: trigger, lazy: lazy, now: now, below: below, onRule: onRule) {
        case .needs(let facts)?:
            return .needs(facts)
        case let .skip(id, reason)?:
            return .skip(.rule(id, reason: reason))
        case .review?:
            return sharedGates(pr: pr, existing: existing) ?? .review
        case nil:
            break
        }
        if let settings { return .skip(settings) }
        return sharedGates(pr: pr, existing: existing) ?? .review
    }

    /// The prbar.yaml settings' answer: why they skip, or nil to review.
    private static func settingsSkip(pr: InboxPR, config: ResolvedRepoConfig) -> ReviewState.SkipReason? {
        // Also a poller filter, but the poller is not the only entry
        // point: the CLI is handed a PR directly and never polls.
        if TitleExclusion.isExcluded(title: pr.title, patterns: config.excludeTitlePatterns) {
            return .titleExcluded
        }
        // Repo opted out of AI triage entirely → ReadinessCoordinator
        // marks these as "ready" immediately on the human side.
        if !config.aiReviewEnabled {
            return .aiReviewDisabled
        }
        // Drafts churn a lot and reviewing them burns cost on
        // intermediate state.
        if pr.isDraft && !config.reviewDrafts {
            return .draftNotReviewed
        }
        // Another human already reviewed, so it's covered. Inbox
        // visibility is governed separately by the opt-in hide filter
        // (same predicate); manual Re-run still works regardless.
        if config.skipAIIfReviewedByOthers && pr.isReviewedByOthers {
            return .reviewedByOthers
        }
        return nil
    }

    private enum SelectOutcome {
        case review
        case skip(String, String?)
        case needs(Set<LazyFact>)
    }

    static func selectFacts(
        pr: InboxPR, rules: Rules, trigger: RuleTrigger, lazy: LazyFactValues, now: Date, below: BelowFacts? = nil
    ) -> SelectFacts {
        SelectFacts(
            pr: ChangeFacts(pr, now: now, files: lazy.files, committers: lazy.committers),
            trigger: trigger, viewer: pr.viewerLogin, lists: rules.lists, now: now, below: below)
    }

    /// What `below` is for `pr`: the settings' answer.
    static func below(pr: InboxPR, config: ResolvedRepoConfig) -> BelowFacts {
        settingsSkip(pr: pr, config: config).map { BelowFacts.settings("skip", reason: $0.detail) } ?? .settings("review")
    }

    /// The layers bottom up, each seeing the one under it as `below`; the
    /// highest that matches decides.
    private static func selectRule(
        pr: InboxPR, config: ResolvedRepoConfig, trigger: RuleTrigger, lazy: LazyFactValues, now: Date,
        below settings: BelowFacts, onRule: ((RuleLayer, SelectFacts, RuleSelection?) -> Void)?
    ) -> SelectOutcome? {
        var below = settings
        var decided: RuleSelection?
        for (layer, rules) in config.ruleLayers where layer == .personal || !rules.select.isEmpty {
            let facts = selectFacts(pr: pr, rules: rules, trigger: trigger, lazy: lazy, now: now, below: below)
            do {
                switch try rules.select(facts, pending: lazy.pending) {
                case .needs(let needed):
                    return .needs(needed)
                case .decided(let selection):
                    onRule?(layer, facts, selection)
                    if let selection {
                        decided = selection
                        below = .rule(selection.rule, action: selection.action.rawValue, reason: selection.reason, layer: layer)
                    }
                }
            } catch {
                // Not reviewing is the side that costs nothing; the reason
                // carries the error to the row and the log.
                PRBarLog.triage.error("select rule failed layer=\(layer.rawValue, privacy: .public) pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public): \(String(describing: error), privacy: .public)")
                return .skip(Rules.errorRuleID, "a select rule failed: \(String(describing: error))")
            }
        }
        guard let decided else { return nil }
        switch decided.action {
        case .review: return .review
        case .skip: return .skip(decided.rule, decided.reason)
        }
    }

    private static func sharedGates(pr: InboxPR, existing: ReviewState?) -> Decision? {
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
        return nil
    }

    private static func holdsCompletedReview(_ existing: ReviewState?, at headSha: String) -> Bool {
        guard let existing, existing.headSha == headSha, case .completed = existing.status else {
            return false
        }
        return true
    }
}
