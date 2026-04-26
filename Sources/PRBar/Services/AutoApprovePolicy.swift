import Foundation

/// Pure function: evaluates whether a completed AI review meets the
/// repo's auto-approve gates. The caller is responsible for actually
/// firing `gh pr review --approve` (and giving the user 30 s to undo).
enum AutoApprovePolicy {
    enum Decision: Sendable, Hashable {
        case approve
        case skip(reason: String)
    }

    static func evaluate(
        pr: InboxPR,
        review: AggregatedReview,
        config: AutoApproveConfig
    ) -> Decision {
        if !config.enabled {
            return .skip(reason: "auto-approve disabled for this repo")
        }
        if review.verdict != .approve {
            return .skip(reason: "AI verdict is \(review.verdict.displayName), not approve")
        }
        if review.confidence < config.minConfidence {
            return .skip(reason: String(
                format: "confidence %.2f below threshold %.2f",
                review.confidence, config.minConfidence
            ))
        }
        if config.requireZeroBlockingAnnotations {
            let blocking = review.annotations.filter { $0.severity.isBlocking }
            if !blocking.isEmpty {
                return .skip(reason: "\(blocking.count) blocking annotation(s)")
            }
        }
        if config.maxAdditions > 0 && pr.totalAdditions > config.maxAdditions {
            return .skip(reason: "PR has +\(pr.totalAdditions) lines, cap is \(config.maxAdditions)")
        }
        return .approve
    }
}
