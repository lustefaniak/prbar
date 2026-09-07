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
    ) -> ResolvedRepoConfig {
        var c = RepoConfig.default
        c.aiReviewEnabled = aiReviewEnabled
        c.reviewDrafts = reviewDrafts
        c.skipAIIfReviewedByOthers = skipAIIfReviewedByOthers
        return c.resolved()
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

    // MARK: another PRBar already reviewed this commit

    /// The point of the whole feature: several reviewers requested on one
    /// PR must not each pay for a review of the same diff. The skip lands
    /// before `enqueue`, so no provider process is spawned at all.
    func testExistingVerdictAtHeadRecordsSkip() {
        let w = makeWorker()
        w.configResolver = { _, _ in Self.config() }
        w.enqueueNewReviewRequests(from: [makePR(nodeId: "P", hasPRBarVerdictAtHead: true)])
        XCTAssertEqual(w.reviews["P"]?.status, .skipped(.reviewedByPRBarElsewhere))
    }

    func testNoVerdictAtHeadDoesNotSkip() {
        let w = makeWorker()
        w.configResolver = { _, _ in Self.config() }
        w.enqueueNewReviewRequests(from: [makePR(nodeId: "P", hasPRBarVerdictAtHead: false)])
        XCTAssertNotEqual(w.reviews["P"]?.status, .skipped(.reviewedByPRBarElsewhere))
    }

    /// The gate is last, so a more specific repo-config reason still wins
    /// the explanation shown on the row.
    func testConfigReasonsBeatTheVerdictReason() {
        let w = makeWorker()
        w.configResolver = { _, _ in Self.config(aiReviewEnabled: false) }
        w.enqueueNewReviewRequests(from: [makePR(nodeId: "P", hasPRBarVerdictAtHead: true)])
        XCTAssertEqual(w.reviews["P"]?.status, .skipped(.aiReviewDisabled))
    }

    /// Our own posted verdict comes back as a marker on the next poll. The
    /// skip has to defer to the completed review we already hold, or
    /// `enqueue`'s cache-hit path never runs and `ReadinessCoordinator`
    /// loses the settled pulse it needs to notify after a relaunch.
    func testOwnCompletedReviewIsNotOverwrittenByTheVerdictSkip() {
        let w = makeWorker()
        var settled: [String] = []
        w.onReviewSettled = { nodeId, _ in settled.append(nodeId) }
        w._setReviewsForScreenshot([
            "P": ReviewState(
                prNodeId: "P", headSha: "abc123",
                triggeredAt: Date(timeIntervalSince1970: 0),
                status: .completed(makeAgg()), costUsd: 0.05
            )
        ])
        w.configResolver = { _, _ in Self.config() }
        w.enqueueNewReviewRequests(from: [makePR(nodeId: "P", hasPRBarVerdictAtHead: true)])
        guard case .completed = w.reviews["P"]?.status else {
            return XCTFail("our own verdict at this head must survive the marker skip")
        }
        XCTAssertEqual(settled, ["P"], "the cache-hit settled pulse must still fire")
    }

    /// A skip recorded on the previous poll must not let the next one fall
    /// through and run the review anyway.
    func testRepeatedPollsKeepSkippingWhileTheVerdictStands() {
        let w = makeWorker()
        w.configResolver = { _, _ in Self.config() }
        let pr = makePR(nodeId: "P", hasPRBarVerdictAtHead: true)
        w.enqueueNewReviewRequests(from: [pr])
        w.enqueueNewReviewRequests(from: [pr])
        XCTAssertEqual(w.reviews["P"]?.status, .skipped(.reviewedByPRBarElsewhere))
    }

    /// A push moves the head SHA past the marker, so the PR is reviewed
    /// again rather than staying skipped forever.
    func testNewHeadWithoutAVerdictReArms() {
        let w = makeWorker()
        w.configResolver = { _, _ in Self.config() }
        w.enqueueNewReviewRequests(from: [makePR(nodeId: "P", headSha: "sha1", hasPRBarVerdictAtHead: true)])
        XCTAssertEqual(w.reviews["P"]?.status, .skipped(.reviewedByPRBarElsewhere))
        w.enqueueNewReviewRequests(from: [makePR(nodeId: "P", headSha: "sha2", hasPRBarVerdictAtHead: false)])
        XCTAssertNotEqual(w.reviews["P"]?.status, .skipped(.reviewedByPRBarElsewhere))
        XCTAssertEqual(w.reviews["P"]?.headSha, "sha2")
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
        headSha: String = "abc123",
        hasPRBarVerdictAtHead: Bool = false
    ) -> InboxPR {
        var pr = makeBasePR(
            nodeId: nodeId, role: role, isDraft: isDraft,
            reviewDecision: reviewDecision, headSha: headSha
        )
        pr.hasPRBarVerdictAtHead = hasPRBarVerdictAtHead
        return pr
    }

    private func makeBasePR(
        nodeId: String,
        role: PRRole,
        isDraft: Bool,
        reviewDecision: String?,
        headSha: String
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
