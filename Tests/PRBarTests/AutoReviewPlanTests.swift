import XCTest
@testable import PRBar

/// `AutoReviewPlan` without the worker: the decision made concrete as the
/// review PRBar would post. `AutoReviewStagingTests` covers the same
/// shapes end to end through the worker and the undo window.
final class AutoReviewPlanTests: XCTestCase {
    private let diff = """
    diff --git a/a.go b/a.go
    --- a/a.go
    +++ b/a.go
    @@ -1,1 +1,2 @@
     package a
    +var x = 1

    """

    private let warning = DiffAnnotation(
        path: "a.go", lineStart: 2, lineEnd: 2, severity: .warning,
        title: "Unchecked", body: "x is never read"
    )
    private let nit = DiffAnnotation(
        path: "a.go", lineStart: 2, lineEnd: 2, severity: .info,
        title: "Nit", body: "rename"
    )

    func testSkipPlansNothing() {
        guard case .none = plan(review(.approve, 0.9), RepoConfig.default) else {
            return XCTFail("every gate ships off")
        }
    }

    func testShareWithAnchoredFindingsHasAnEmptyBody() throws {
        var rule = RepoConfig.default
        rule.shareFindings = .warningsAndBlockers
        guard case let .post(staged) = plan(review(.approve, 0.7, [warning, nit]), rule) else {
            return XCTFail("expected a share")
        }
        XCTAssertEqual(staged.action, .comment)
        XCTAssertEqual(staged.source, .sharedFindings)
        XCTAssertEqual(staged.body, "", "inline findings are the review")
        XCTAssertEqual(staged.comments.count, 1, "the nit is under the warnings floor")
    }

    func testShareWithNothingAnchoredKeepsTheSummary() throws {
        var rule = RepoConfig.default
        rule.shareFindings = .warningsAndBlockers
        let off = DiffAnnotation(path: "other.go", lineStart: 9, lineEnd: 9, severity: .warning, title: "T", body: "b")
        guard case let .post(staged) = plan(review(.approve, 0.7, [off]), rule) else {
            return XCTFail("expected a share")
        }
        XCTAssertTrue(staged.comments.isEmpty)
        XCTAssertEqual(staged.body, "summary", "GitHub rejects an empty COMMENT with no inline comments")
    }

    func testFlagOnlyDenialIsFlaggedNotPosted() throws {
        var rule = RepoConfig.default
        rule.autoDeny = AutoDenyConfig(action: .flagOnly)
        guard case let .flag(staged) = plan(review(.requestChanges, 0.95, [warning]), rule) else {
            return XCTFail("expected a flag")
        }
        XCTAssertEqual(staged.body, "summary")
    }

    func testRequestChangesFallsBackWhenTheSummaryIsBlank() throws {
        var rule = RepoConfig.default
        rule.autoDeny = AutoDenyConfig(action: .requestChanges)
        guard case let .post(staged) = plan(review(.requestChanges, 0.95, [warning], summary: "  "), rule) else {
            return XCTFail("expected a post")
        }
        XCTAssertEqual(staged.action, .requestChanges)
        XCTAssertTrue(staged.body.contains("95%"), staged.body)
    }

    // MARK: - helpers

    private func plan(_ review: AggregatedReview, _ rule: RepoConfig) -> AutoReviewPlan.Outcome {
        AutoReviewPlan.plan(
            pr: makePR(), review: review, config: rule.resolved(), providerId: .claude,
            diffText: diff, now: Date(timeIntervalSince1970: 0)
        )
    }

    private func review(
        _ verdict: ReviewVerdict,
        _ confidence: Double,
        _ annotations: [DiffAnnotation] = [],
        summary: String = "summary"
    ) -> AggregatedReview {
        AggregatedReview(
            verdict: verdict, confidence: confidence, summaryMarkdown: summary, annotations: annotations,
            costUsd: 0.01, toolCallCount: 0, toolNamesUsed: [], perSubreview: [], isSubscriptionAuth: false
        )
    }

    private func makePR() -> InboxPR {
        InboxPR(
            nodeId: "PR_1", owner: "o", repo: "r", number: 1,
            title: "t", body: "", url: URL(string: "https://github.com/o/r/pull/1")!,
            author: "a", headRef: "h", baseRef: "main",
            headSha: "abc123", isDraft: false,
            role: .reviewRequested,
            mergeable: "MERGEABLE", mergeStateStatus: "CLEAN", reviewDecision: nil,
            checkRollupState: "SUCCESS",
            totalAdditions: 1, totalDeletions: 0, changedFiles: 1,
            hasAutoMerge: false, autoMergeEnabledBy: nil, allCheckSummaries: [],
            allowedMergeMethods: [.squash], autoMergeAllowed: false, deleteBranchOnMerge: false
        )
    }
}
