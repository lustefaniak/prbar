import Foundation

/// Pure function: decides what — if anything — PRBar should post on its
/// own once an AI review completes. Two independent sides, because the
/// bar for letting a bot approve differs from the bar for letting it push
/// back: `RepoConfig.autoApprove` gates the positive verdicts and
/// `RepoConfig.autoDeny` the negative one.
///
/// The caller stages the decision behind the undo window and owns the
/// actual `gh` write.
enum AutoReviewPolicy {
    enum Decision: Sendable, Hashable {
        case approve
        /// Negative verdict cleared the deny gates. The payload is never
        /// `.off` — `.flagOnly` means "surface it, post nothing".
        case deny(AutoDenyAction)
        case skip(reason: String)
    }

    static func evaluate(
        pr: InboxPR,
        review: AggregatedReview,
        providerId: ProviderID,
        config: ResolvedRepoConfig
    ) -> Decision {
        switch review.verdict {
        case .approve:
            return evaluateApprove(pr: pr, review: review, providerId: providerId, config: config.autoApprove)
        case .comment:
            guard config.autoApprove.allowApproveWithNotes else {
                return .skip(reason: "AI verdict is \(review.verdict.displayName); auto-approve with notes is off")
            }
            return evaluateApprove(pr: pr, review: review, providerId: providerId, config: config.autoApprove)
        case .requestChanges:
            return evaluateDeny(pr: pr, review: review, providerId: providerId, config: config.autoDeny)
        case .abstain:
            return .skip(reason: "AI abstained")
        }
    }

    // MARK: - approve side

    static func evaluateApprove(
        pr: InboxPR,
        review: AggregatedReview,
        providerId: ProviderID,
        config: AutoApproveConfig
    ) -> Decision {
        if !config.enabled {
            return .skip(reason: "auto-approve disabled for this repo")
        }
        let floor = config.confidenceFloor(for: providerId)
        if review.confidence < floor {
            return .skip(reason: String(
                format: "confidence %.2f below %@ threshold %.2f",
                review.confidence, providerId.displayName, floor
            ))
        }
        let overSeverity = review.annotations.filter { $0.severity > config.maxAnnotationSeverity }
        if !overSeverity.isEmpty {
            return .skip(reason: "\(overSeverity.count) annotation(s) above \(config.maxAnnotationSeverity.displayName)")
        }
        if config.maxAnnotations > 0 && review.annotations.count > config.maxAnnotations {
            return .skip(reason: "\(review.annotations.count) annotations, cap is \(config.maxAnnotations)")
        }
        if let reason = sizeSkipReason(
            pr: pr,
            maxAdditions: config.maxAdditions,
            maxDeletions: config.maxDeletions,
            maxChangedFiles: config.maxChangedFiles
        ) {
            return .skip(reason: reason)
        }
        return .approve
    }

    // MARK: - deny side

    static func evaluateDeny(
        pr: InboxPR,
        review: AggregatedReview,
        providerId: ProviderID,
        config: AutoDenyConfig
    ) -> Decision {
        if config.action == .off {
            return .skip(reason: "auto-deny disabled for this repo")
        }
        let floor = config.confidenceFloor(for: providerId)
        if review.confidence < floor {
            return .skip(reason: String(
                format: "confidence %.2f below %@ deny threshold %.2f",
                review.confidence, providerId.displayName, floor
            ))
        }
        if config.minMatchingAnnotations > 0 {
            let matching = review.annotations.filter { $0.severity >= config.requiredSeverity }
            if matching.count < config.minMatchingAnnotations {
                let label = config.requiredSeverity.displayName.lowercased()
                return .skip(reason: "\(matching.count) \(label)+ annotation(s), need \(config.minMatchingAnnotations)")
            }
        }
        if let reason = sizeSkipReason(
            pr: pr,
            maxAdditions: config.maxAdditions,
            maxDeletions: 0,
            maxChangedFiles: 0
        ) {
            return .skip(reason: reason)
        }
        return .deny(config.action)
    }

    // MARK: - shared gates

    /// Nil when the PR fits every non-zero cap. 0 means unlimited on each.
    private static func sizeSkipReason(
        pr: InboxPR,
        maxAdditions: Int,
        maxDeletions: Int,
        maxChangedFiles: Int
    ) -> String? {
        if maxAdditions > 0 && pr.totalAdditions > maxAdditions {
            return "PR has +\(pr.totalAdditions) lines, cap is \(maxAdditions)"
        }
        if maxDeletions > 0 && pr.totalDeletions > maxDeletions {
            return "PR has -\(pr.totalDeletions) lines, cap is \(maxDeletions)"
        }
        if maxChangedFiles > 0 && pr.changedFiles > maxChangedFiles {
            return "PR touches \(pr.changedFiles) files, cap is \(maxChangedFiles)"
        }
        return nil
    }
}
