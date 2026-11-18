import Foundation

/// The GitHub review that accepts PRBar's recommendation for a PR, as the
/// app's primary post button sends it: the action the verdict stands for
/// ("approve with notes" is an approval with a body), the summary as the
/// body unless the user wrote their own, and the findings as inline
/// comments wherever they land on the diff. `review.post` uses it so a
/// client without the app's UI (`prbar-review post`) posts the same review.
enum RecommendedReview {
    enum Plan: Equatable {
        case post(GHActionKind)
        case refuse(String)
    }

    /// `state` is PRBar's review of the PR, `headSha` the PR's current head.
    /// `body` replaces the summary when given. `diffText` is the PR's diff;
    /// it only matters when the review has findings.
    static func plan(state: ReviewState?, headSha: String, body: String?, diffText: String) -> Plan {
        guard let state else { return .refuse("PRBar hasn't reviewed this PR") }
        guard case .completed(let review) = state.status else {
            return .refuse("PRBar's review of this PR hasn't completed")
        }
        // A verdict on an older commit says nothing about what is there now.
        guard state.headSha == headSha else {
            return .refuse("PRBar's review is of \(state.headSha.prefix(7)), not the PR's head \(headSha.prefix(7))")
        }
        guard let kind = action(for: review.verdict) else {
            return .refuse("PRBar abstained, so it recommends no review")
        }
        let text = (body ?? review.summaryMarkdown).trimmingCharacters(in: .whitespacesAndNewlines)
        // GitHub rejects a request for changes without a body.
        if kind == .requestChanges, text.isEmpty {
            return .refuse("a request for changes needs a body")
        }
        let comments = review.annotations.isEmpty
            ? []
            : InlineCommentMapper.map(annotations: review.annotations, hunks: DiffParser.parse(diffText))
        return .post(.review(kind: kind, body: text, comments: comments))
    }

    static func action(for verdict: ReviewVerdict) -> ReviewActionKind? {
        switch verdict {
        case .approve, .comment: return .approve
        case .requestChanges: return .requestChanges
        case .abstain: return nil
        }
    }
}
