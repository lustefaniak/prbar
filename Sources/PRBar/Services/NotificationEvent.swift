import Foundation

struct NotificationEvent: Sendable, Hashable, Codable {
    enum Kind: String, Sendable, Codable, Hashable {
        case readyToMerge
        case newReviewRequest
        case ciFailed
    }

    let kind: Kind
    let prNodeId: String
    let prTitle: String
    let prRepo: String          // "owner/repo"
    let prNumber: Int
    let prURL: URL
}

enum EventDeriver {
    /// Pure function: given a poll delta and the old list of PRs, return
    /// the user-facing events worth notifying about. This is the only
    /// place that defines what "actionable change" means.
    ///
    /// Note: `.newReviewRequest` events are NOT emitted here anymore —
    /// `ReadinessCoordinator` owns that signal so it can apply the
    /// per-repo `NotifyPolicy` (immediate vs. wait-for-AI-to-settle).
    /// EventDeriver still handles author-side state transitions
    /// (ready-to-merge, CI failures).
    static func events(from delta: PollDelta, oldPRs: [InboxPR]) -> [NotificationEvent] {
        var events: [NotificationEvent] = []
        let oldByID = Dictionary(uniqueKeysWithValues: oldPRs.map { ($0.nodeId, $0) })

        // PRs I authored that just became ready-to-merge (transition).
        for pr in delta.changed where pr.role == .authored || pr.role == .both {
            let was = oldByID[pr.nodeId].map(isReadyToMerge) ?? false
            let now = isReadyToMerge(pr)
            if !was && now {
                events.append(.init(
                    kind: .readyToMerge,
                    prNodeId: pr.nodeId,
                    prTitle: pr.title,
                    prRepo: pr.nameWithOwner,
                    prNumber: pr.number,
                    prURL: pr.url
                ))
            }

            // CI flipped to failing (worth interrupting for).
            let oldFailing = isFailing(oldByID[pr.nodeId])
            let nowFailing = isFailing(pr)
            if !oldFailing && nowFailing {
                events.append(.init(
                    kind: .ciFailed,
                    prNodeId: pr.nodeId,
                    prTitle: pr.title,
                    prRepo: pr.nameWithOwner,
                    prNumber: pr.number,
                    prURL: pr.url
                ))
            }
        }

        // Newly-added PRs I authored that are already mergeable (e.g. I
        // re-opened the app and a long-pending PR finally got approved
        // while we were away).
        for pr in delta.added where (pr.role == .authored || pr.role == .both) && isReadyToMerge(pr) {
            events.append(.init(
                kind: .readyToMerge,
                prNodeId: pr.nodeId,
                prTitle: pr.title,
                prRepo: pr.nameWithOwner,
                prNumber: pr.number,
                prURL: pr.url
            ))
        }

        return events
    }

    static func isReadyToMerge(_ pr: InboxPR) -> Bool {
        guard !pr.isDraft else { return false }
        guard pr.mergeStateStatus == "CLEAN" else { return false }
        guard pr.reviewDecision == "APPROVED" else { return false }
        return true
    }

    private static func isFailing(_ pr: InboxPR?) -> Bool {
        guard let pr else { return false }
        return pr.checkRollupState == "FAILURE" || pr.checkRollupState == "ERROR"
    }
}
