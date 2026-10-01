import Foundation

/// Classification of an authored PR by the single state that most demands the
/// author's attention. The same categories drive both the My PRs list sort
/// order and the `MyPRsScope` visibility filter, so the two can never disagree.
///
/// Precedence matches GitHub's own signal priority: merge state first
/// (mergeable / blocked / conflicting), then CI, then review decision. A PR
/// that is e.g. blocked-but-approved *and* failing CI classifies as
/// `.approvedWaiting` because the merge state is the stronger signal.
///
/// `Comparable` is synthesized from declaration order, so the case order below
/// *is* the list sort order (ready-to-merge first, drafts last) — there is no
/// separate rank to keep in sync.
enum MyPRsCategory: Sendable, Hashable, Comparable {
    case readyToMerge      // CLEAN + APPROVED — can merge now
    case approvedWaiting   // BLOCKED + APPROVED — approved, merge still gated
    case changesRequested  // a reviewer asked for changes
    case redCI             // CI failed/errored
    case conflicts         // DIRTY / CONFLICTING — needs rebase
    case ciInFlight        // CI pending/expected
    case reviewRequired    // no decision yet
    case other             // none of the above
    case draft             // draft PR

    static func of(_ pr: InboxPR) -> MyPRsCategory {
        if pr.isDraft { return .draft }
        switch pr.mergeStateStatus {
        case "CLEAN" where pr.reviewDecision == "APPROVED":     return .readyToMerge
        case "BLOCKED" where pr.reviewDecision == "APPROVED":   return .approvedWaiting
        case "DIRTY", "CONFLICTING":                            return .conflicts
        default: break
        }
        switch pr.checkRollupState {
        case "FAILURE", "ERROR":    return .redCI
        case "PENDING", "EXPECTED": return .ciInFlight
        default: break
        }
        if pr.reviewDecision == "CHANGES_REQUESTED" { return .changesRequested }
        if pr.reviewDecision == "REVIEW_REQUIRED"   { return .reviewRequired }
        return .other
    }
}

/// How narrowly the My PRs list is filtered. Drafts are out of scope here —
/// their visibility is owned entirely by `MyDraftHandling`; this filter only
/// ever applies to non-draft authored PRs.
enum MyPRsScope: String, CaseIterable, Sendable, Hashable {
    /// Every non-draft authored PR (no narrowing).
    case all
    /// Only PRs where the author has something to do: ready-to-merge,
    /// approved-but-waiting (a manual nudge may still be needed — a CI race,
    /// a stale base), changes-requested, red CI, conflicts.
    case needsAttention
    /// Of the non-draft PRs, only those the menu-bar badge counts:
    /// ready-to-merge + red CI, respecting the badge source toggles. (Drafts
    /// follow `MyDraftHandling`, so a silenced draft can still be listed while
    /// the badge excludes it — see `visibleAuthored`.)
    case counterOnly

    static let storageKey = "myPRsScope"
    static let `default`: MyPRsScope = .all

    var pickerLabel: String {
        switch self {
        case .all:            return "All authored PRs"
        case .needsAttention: return "Needs my attention"
        case .counterOnly:    return "Only badge-counted"
        }
    }

    /// Categories shown under `.needsAttention`.
    private static let attentionCategories: Set<MyPRsCategory> =
        [.readyToMerge, .approvedWaiting, .changesRequested, .redCI, .conflicts]

    /// Whether a non-draft authored PR is visible under this scope. Callers
    /// pass non-drafts only — draft visibility is `MyDraftHandling`'s job, so
    /// role and draft gating happen in `visibleAuthored` before this is called.
    /// `badgeReadyToMerge` / `badgeCIFailed` are the menu-bar badge source
    /// toggles; `.counterOnly` shows a PR exactly when it contributes to an
    /// authored badge counter, using the same `EventDeriver` predicates the
    /// badge does, so the list and the badge agree on what "counted" means.
    func includes(
        _ pr: InboxPR,
        badgeReadyToMerge: Bool,
        badgeCIFailed: Bool
    ) -> Bool {
        switch self {
        case .all:
            return true
        case .needsAttention:
            return Self.attentionCategories.contains(MyPRsCategory.of(pr))
        case .counterOnly:
            return (badgeReadyToMerge && EventDeriver.isReadyToMerge(pr))
                || (badgeCIFailed && EventDeriver.isFailing(pr))
        }
    }

    /// The authored PRs visible in My PRs after role filtering, draft handling,
    /// and this scope (unsorted). The single definition behind both the My PRs
    /// list and its segmented-tab count, so the two can't drift apart. Draft
    /// visibility is owned by `draftHandling`; the scope only narrows non-drafts.
    static func visibleAuthored(
        from prs: [InboxPR],
        draftHandling: MyDraftHandling,
        scope: MyPRsScope,
        badgeReadyToMerge: Bool,
        badgeCIFailed: Bool
    ) -> [InboxPR] {
        let hideDrafts = draftHandling.hidesFromMyPRs
        return prs
            .filter { $0.role == .authored || $0.role == .both }
            .filter { !(hideDrafts && $0.isDraft) }
            .filter { $0.isDraft || scope.includes($0, badgeReadyToMerge: badgeReadyToMerge, badgeCIFailed: badgeCIFailed) }
    }
}
