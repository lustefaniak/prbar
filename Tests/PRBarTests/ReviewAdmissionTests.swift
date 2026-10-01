import XCTest
@testable import PRBar

/// The select stage on its own: values in, decision out. The worker-level
/// behaviour (recording the skip, the cache-hit pulse) is covered in
/// `ReviewSkipStateTests`; these pin the gates and their order.
final class ReviewAdmissionTests: XCTestCase {
    func testReviewRequestedPRIsAdmitted() {
        XCTAssertEqual(evaluate(makePR()), .review)
        XCTAssertEqual(evaluate(makePR(role: .both)), .review)
    }

    func testPRsNotRequestedFromTheViewerAreIgnored() {
        XCTAssertEqual(evaluate(makePR(role: .authored)), .ignore(.notRequested))
        XCTAssertEqual(evaluate(makePR(role: .other)), .ignore(.notRequested))
    }

    func testEachGateSkipsWithItsOwnReason() {
        var titled = RepoConfig.default
        titled.excludeTitlePatterns = ["chore: bump *"]
        XCTAssertEqual(evaluate(makePR(title: "chore: bump yams"), rule: titled), .skip(.titleExcluded))

        var off = RepoConfig.default
        off.aiReviewEnabled = false
        XCTAssertEqual(evaluate(makePR(), rule: off), .skip(.aiReviewDisabled))

        XCTAssertEqual(evaluate(makePR(isDraft: true)), .skip(.draftNotReviewed))
        var drafts = RepoConfig.default
        drafts.reviewDrafts = true
        XCTAssertEqual(evaluate(makePR(isDraft: true), rule: drafts), .review)

        XCTAssertEqual(evaluate(makePR(reviewDecision: "APPROVED")), .skip(.reviewedByOthers))
        var keepGoing = RepoConfig.default
        keepGoing.skipAIIfReviewedByOthers = false
        XCTAssertEqual(evaluate(makePR(reviewDecision: "APPROVED"), rule: keepGoing), .review)

        XCTAssertEqual(evaluate(makePR(verdictAtHead: true)), .skip(.reviewedByPRBarElsewhere))
    }

    /// The first matching gate names the reason, so a draft whose repo
    /// has AI review off reads "AI review off", not "draft".
    func testTheMoreSpecificRepoReasonWins() {
        var off = RepoConfig.default
        off.aiReviewEnabled = false
        XCTAssertEqual(evaluate(makePR(isDraft: true, verdictAtHead: true), rule: off), .skip(.aiReviewDisabled))
    }

    func testFailureAtTheCurrentHeadIsNotRetried() {
        let failed = state(sha: "abc123", status: .failed("boom"))
        XCTAssertEqual(evaluate(makePR(), existing: failed), .ignore(.failedAtCurrentSha))
        // A new commit re-arms it.
        XCTAssertEqual(evaluate(makePR(headSha: "def456"), existing: failed), .review)
    }

    /// A completed review this instance holds for the same head goes
    /// through, so `enqueue`'s cache-hit path still fires the settled pulse.
    func testOwnCompletedReviewBeatsTheMarker() {
        let done = state(sha: "abc123", status: .completed(Self.review))
        XCTAssertEqual(evaluate(makePR(verdictAtHead: true), existing: done), .review)
        let stale = state(sha: "old", status: .completed(Self.review))
        XCTAssertEqual(evaluate(makePR(verdictAtHead: true), existing: stale), .skip(.reviewedByPRBarElsewhere))
    }

    // MARK: - helpers

    private func evaluate(
        _ pr: InboxPR,
        rule: RepoConfig = .default,
        existing: ReviewState? = nil
    ) -> ReviewAdmission.Decision {
        ReviewAdmission.evaluate(pr: pr, config: rule.resolved(), existing: existing)
    }

    private func state(sha: String, status: ReviewState.Status) -> ReviewState {
        ReviewState(prNodeId: "PR_1", headSha: sha, triggeredAt: Date(), status: status, costUsd: 0)
    }

    private static let review = AggregatedReview(
        verdict: .approve, confidence: 0.9, summaryMarkdown: "ok", annotations: [],
        costUsd: 0, toolCallCount: 0, toolNamesUsed: [], perSubreview: [], isSubscriptionAuth: false
    )

    private func makePR(
        role: PRRole = .reviewRequested,
        title: String = "t",
        isDraft: Bool = false,
        reviewDecision: String? = nil,
        headSha: String = "abc123",
        verdictAtHead: Bool = false
    ) -> InboxPR {
        var pr = InboxPR(
            nodeId: "PR_1", owner: "o", repo: "r", number: 1,
            title: title, body: "", url: URL(string: "https://github.com/o/r/pull/1")!,
            author: "a", headRef: "h", baseRef: "main",
            headSha: headSha, isDraft: isDraft,
            role: role,
            mergeable: "MERGEABLE", mergeStateStatus: "BLOCKED", reviewDecision: reviewDecision,
            checkRollupState: "PENDING",
            totalAdditions: 1, totalDeletions: 0, changedFiles: 1,
            hasAutoMerge: false, autoMergeEnabledBy: nil, allCheckSummaries: [],
            allowedMergeMethods: [.squash], autoMergeAllowed: true, deleteBranchOnMerge: true
        )
        pr.hasPRBarVerdictAtHead = verdictAtHead
        return pr
    }
}
