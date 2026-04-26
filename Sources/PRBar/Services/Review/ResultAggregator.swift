import Foundation

/// PR-level outcome rolled up from one or more `ProviderResult`s (one per
/// Subdiff). Aggregation rules:
/// - `verdict` = worst across subreviews (`request_changes` > `comment` >
///   `approve` > `abstain`).
/// - `confidence` = min across subreviews that returned a verdict.
/// - `summary` = subreview summaries concatenated under `## <subpath>`
///   headings (or `## Summary` when there's only one subreview).
/// - `annotations` = all merged, with `path` rewritten to be repo-relative
///   (subpath-prefixed) so the diff overlay can locate them globally.
/// - `costUsd` = sum.
/// - `toolCallCount` = sum; `toolNamesUsed` deduped union.
struct AggregatedReview: Sendable, Hashable, Codable {
    let verdict: ReviewVerdict
    let confidence: Double
    let summaryMarkdown: String
    let annotations: [DiffAnnotation]
    let costUsd: Double
    let toolCallCount: Int
    let toolNamesUsed: [String]
    let perSubreview: [SubreviewOutcome]

    /// True when *every* subreview ran on subscription auth — the cost is
    /// purely informational (API-equivalent). If any subreview was billed
    /// (mixed-auth setup), we treat the whole thing as billed.
    let isSubscriptionAuth: Bool
}

struct SubreviewOutcome: Sendable, Hashable, Codable {
    let subpath: String           // empty = repo root
    let result: ProviderResult
}

extension ProviderResult: Hashable {
    public static func == (lhs: ProviderResult, rhs: ProviderResult) -> Bool {
        lhs.verdict == rhs.verdict
            && lhs.confidence == rhs.confidence
            && lhs.summaryMarkdown == rhs.summaryMarkdown
            && lhs.annotations == rhs.annotations
            && lhs.costUsd == rhs.costUsd
            && lhs.toolCallCount == rhs.toolCallCount
            && lhs.toolNamesUsed == rhs.toolNamesUsed
            && lhs.rawJson == rhs.rawJson
            && lhs.isSubscriptionAuth == rhs.isSubscriptionAuth
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(verdict)
        hasher.combine(confidence)
        hasher.combine(summaryMarkdown)
        hasher.combine(annotations)
        hasher.combine(costUsd)
        hasher.combine(toolCallCount)
        hasher.combine(toolNamesUsed)
        hasher.combine(rawJson)
        hasher.combine(isSubscriptionAuth)
    }
}

enum ResultAggregator {
    /// Aggregate one or more subreview results. Throws if the input is
    /// empty (callers should never invoke with [], but be explicit).
    static func aggregate(_ outcomes: [SubreviewOutcome]) -> AggregatedReview? {
        guard !outcomes.isEmpty else { return nil }

        // Worst verdict by severityRank.
        let verdict = outcomes
            .map(\.result.verdict)
            .max(by: { $0.severityRank < $1.severityRank })
            ?? .abstain

        // Min confidence among non-abstain results (abstain confidence is
        // less meaningful — it's "I don't know"). Fall back to overall min.
        let nonAbstain = outcomes.filter { $0.result.verdict != .abstain }
        let candidateConfidences = (nonAbstain.isEmpty ? outcomes : nonAbstain)
            .map(\.result.confidence)
        let confidence = candidateConfidences.min() ?? 0

        let summary = aggregateSummary(outcomes: outcomes)
        let annotations = aggregateAnnotations(outcomes: outcomes)
        let costUsd = outcomes.reduce(0.0) { $0 + ($1.result.costUsd ?? 0) }
        let toolCallCount = outcomes.reduce(0) { $0 + $1.result.toolCallCount }
        let toolNamesUsed = aggregateToolNames(outcomes: outcomes)

        // All-subscription only counts as subscription-billed; any single
        // billed subreview means cost is real and shouldn't be grayed.
        let allSubscription = outcomes.allSatisfy { $0.result.isSubscriptionAuth }

        return AggregatedReview(
            verdict: verdict,
            confidence: confidence,
            summaryMarkdown: summary,
            annotations: annotations,
            costUsd: costUsd,
            toolCallCount: toolCallCount,
            toolNamesUsed: toolNamesUsed,
            perSubreview: outcomes,
            isSubscriptionAuth: allSubscription
        )
    }

    // MARK: - private

    private static func aggregateSummary(outcomes: [SubreviewOutcome]) -> String {
        if outcomes.count == 1 {
            return outcomes[0].result.summaryMarkdown
        }
        var s = ""
        for outcome in outcomes {
            let title = outcome.subpath.isEmpty ? "(repo root)" : outcome.subpath
            s += "## `\(title)` — \(outcome.result.verdict.displayName)\n\n"
            s += outcome.result.summaryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
            s += "\n\n"
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func aggregateAnnotations(outcomes: [SubreviewOutcome]) -> [DiffAnnotation] {
        var out: [DiffAnnotation] = []
        for outcome in outcomes {
            for ann in outcome.result.annotations {
                // Rewrite annotation path to be repo-relative. The AI sees
                // paths relative to its cwd (the subfolder), so we prepend
                // the subpath here so the global diff overlay can locate
                // the line. Empty subpath = repo root, no rewrite.
                let path: String
                if outcome.subpath.isEmpty {
                    path = ann.path
                } else if ann.path.hasPrefix("\(outcome.subpath)/") {
                    // AI may have already returned repo-relative — leave alone.
                    path = ann.path
                } else {
                    path = "\(outcome.subpath)/\(ann.path)"
                }
                out.append(DiffAnnotation(
                    path: path,
                    lineStart: ann.lineStart,
                    lineEnd: ann.lineEnd,
                    severity: ann.severity,
                    body: ann.body
                ))
            }
        }
        return out
    }

    private static func aggregateToolNames(outcomes: [SubreviewOutcome]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for outcome in outcomes {
            for name in outcome.result.toolNamesUsed where seen.insert(name).inserted {
                out.append(name)
            }
        }
        return out
    }
}
