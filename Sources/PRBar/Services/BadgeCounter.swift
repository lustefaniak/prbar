import Foundation

/// Pure derivation of the menu-bar badge text from the inbox + user
/// preferences. Three independent counters — each toggleable in Settings —
/// summed into one number for the status item title. Returns "" when
/// nothing is actionable so the status item shows just the icon.
enum BadgeCounter {
    struct Counts: Sendable, Hashable {
        var readyToMerge: Int = 0
        var reviewRequested: Int = 0
        var ciFailed: Int = 0

        var total: Int { readyToMerge + reviewRequested + ciFailed }
    }

    /// Per-source toggles. All default on.
    struct Sources: Sendable, Hashable {
        var readyToMerge: Bool
        var reviewRequested: Bool
        var ciFailed: Bool

        static let allOn = Sources(
            readyToMerge: true,
            reviewRequested: true,
            ciFailed: true
        )
    }

    /// Derive the (filtered) counts. Only enabled sources contribute.
    static func counts(prs: [InboxPR], sources: Sources) -> Counts {
        var c = Counts()
        for pr in prs {
            if sources.readyToMerge,
               (pr.role == .authored || pr.role == .both),
               EventDeriver.isReadyToMerge(pr) {
                c.readyToMerge += 1
            }
            if sources.reviewRequested,
               (pr.role == .reviewRequested || pr.role == .both),
               !pr.isDraft,
               pr.reviewDecision != "APPROVED" {
                c.reviewRequested += 1
            }
            if sources.ciFailed,
               (pr.role == .authored || pr.role == .both),
               (pr.checkRollupState == "FAILURE" || pr.checkRollupState == "ERROR") {
                c.ciFailed += 1
            }
        }
        return c
    }

    /// Display string for the status item button title. Empty when
    /// nothing is actionable.
    static func title(prs: [InboxPR], sources: Sources) -> String {
        let total = counts(prs: prs, sources: sources).total
        return total > 0 ? "\(total)" : ""
    }
}
