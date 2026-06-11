import XCTest
@testable import PRBar

/// Auto-triage records a terminal `.skipped(reason)` ReviewState when it
/// deliberately declines to review a request, so the inbox row and detail
/// pane can explain *why* instead of showing a perpetual "not started".
@MainActor
final class ReviewSkipStateTests: XCTestCase {

    private func makeWorker() -> ReviewQueueWorker {
        // No review ever actually runs in these tests — every PR hits a skip
        // branch before enqueue would invoke the provider — so an empty diff
        // fetcher and nil checkout/cache are enough.
        ReviewQueueWorker(diffFetcher: { _, _, _ in "" })
    }

    nonisolated private static func config(
        aiReviewEnabled: Bool = true,
        reviewDrafts: Bool = false,
        skipAIIfReviewedByOthers: Bool = true
    ) -> RepoConfig {
        var c = RepoConfig.default
        c.aiReviewEnabled = aiReviewEnabled
        c.reviewDrafts = reviewDrafts
        c.skipAIIfReviewedByOthers = skipAIIfReviewedByOthers
        return c
    }

    // MARK: each repo-config reason is recorded

    func testAIDisabledRecordsSkip() {
        let w = makeWorker()
        w.configResolver = { _, _ in Self.config(aiReviewEnabled: false) }
        w.enqueueNewReviewRequests(from: [makePR(nodeId: "A")])
        XCTAssertEqual(w.reviews["A"]?.status, .skipped(.aiReviewDisabled))
    }

    func testDraftWithoutReviewDraftsRecordsSkip() {
        let w = makeWorker()
        w.configResolver = { _, _ in Self.config(reviewDrafts: false) }
        w.enqueueNewReviewRequests(from: [makePR(nodeId: "D", isDraft: true)])
        XCTAssertEqual(w.reviews["D"]?.status, .skipped(.draftNotReviewed))
    }

    func testReviewedByOthersRecordsSkip() {
        let w = makeWorker()
        w.configResolver = { _, _ in Self.config(skipAIIfReviewedByOthers: true) }
        w.enqueueNewReviewRequests(from: [makePR(nodeId: "R", reviewDecision: "APPROVED")])
        XCTAssertEqual(w.reviews["R"]?.status, .skipped(.reviewedByOthers))
    }

    /// Precedence matches the gate order in `enqueueNewReviewRequests`:
    /// AI-disabled is checked before draft, so a disabled-repo draft reports
    /// the disabled reason (not the draft reason).
    func testAIDisabledBeatsDraftReason() {
        let w = makeWorker()
        w.configResolver = { _, _ in Self.config(aiReviewEnabled: false, reviewDrafts: false) }
        w.enqueueNewReviewRequests(from: [makePR(nodeId: "AD", isDraft: true)])
        XCTAssertEqual(w.reviews["AD"]?.status, .skipped(.aiReviewDisabled))
    }

    // MARK: a skip never masks a real review

    func testSkipDoesNotMaskCompletedReviewAtSameHead() {
        let w = makeWorker()
        w._setReviewsForScreenshot([
            "C": ReviewState(
                prNodeId: "C", headSha: "abc123",
                triggeredAt: Date(timeIntervalSince1970: 0),
                status: .completed(makeAgg()), costUsd: 0.05
            )
        ])
        w.configResolver = { _, _ in Self.config(aiReviewEnabled: false) }
        w.enqueueNewReviewRequests(from: [makePR(nodeId: "C", headSha: "abc123")])
        guard case .completed = w.reviews["C"]?.status else {
            return XCTFail("a completed verdict at the current head must not be overwritten by a skip")
        }
    }

    // MARK: re-arm on new head, no churn on repeat

    func testSkipReArmsOnNewHead() {
        let w = makeWorker()
        w.configResolver = { _, _ in Self.config(aiReviewEnabled: false) }
        w.enqueueNewReviewRequests(from: [makePR(nodeId: "S", headSha: "sha1")])
        XCTAssertEqual(w.reviews["S"]?.headSha, "sha1")
        w.enqueueNewReviewRequests(from: [makePR(nodeId: "S", headSha: "sha2")])
        XCTAssertEqual(w.reviews["S"]?.headSha, "sha2")
        XCTAssertEqual(w.reviews["S"]?.status, .skipped(.aiReviewDisabled))
    }

    func testRepeatSkipDoesNotRewriteEntry() {
        let w = makeWorker()
        w.configResolver = { _, _ in Self.config(aiReviewEnabled: false) }
        let pr = makePR(nodeId: "N", headSha: "sha1")
        w.enqueueNewReviewRequests(from: [pr])
        let first = w.reviews["N"]?.triggeredAt
        w.enqueueNewReviewRequests(from: [pr])
        XCTAssertEqual(w.reviews["N"]?.triggeredAt, first,
                       "an unchanged skip must not rewrite the entry (avoids churn / persistence thrash)")
    }

    // MARK: helpers

    private func makeAgg() -> AggregatedReview {
        let result = ProviderResult(
            verdict: .approve, confidence: 0.9, summaryMarkdown: "ok",
            annotations: [], costUsd: 0.05,
            toolCallCount: 0, toolNamesUsed: [], rawJson: Data()
        )
        return AggregatedReview(
            verdict: .approve, confidence: 0.9, summaryMarkdown: "ok",
            annotations: [], costUsd: 0.05,
            toolCallCount: 0, toolNamesUsed: [],
            perSubreview: [SubreviewOutcome(subpath: "", result: result)],
            isSubscriptionAuth: false
        )
    }

    private func makePR(
        nodeId: String,
        role: PRRole = .reviewRequested,
        isDraft: Bool = false,
        reviewDecision: String? = nil,
        headSha: String = "abc123"
    ) -> InboxPR {
        InboxPR(
            nodeId: nodeId,
            owner: "o",
            repo: "r",
            number: 1,
            title: "t",
            body: "",
            url: URL(string: "https://github.com/o/r/pull/1")!,
            author: "a",
            headRef: "h",
            baseRef: "main",
            headSha: headSha,
            isDraft: isDraft,
            role: role,
            mergeable: "MERGEABLE",
            mergeStateStatus: "BLOCKED",
            reviewDecision: reviewDecision,
            checkRollupState: "PENDING",
            totalAdditions: 1,
            totalDeletions: 0,
            changedFiles: 1,
            hasAutoMerge: false,
            autoMergeEnabledBy: nil,
            allCheckSummaries: [],
            allowedMergeMethods: [.squash],
            autoMergeAllowed: true,
            deleteBranchOnMerge: true
        )
    }
}
