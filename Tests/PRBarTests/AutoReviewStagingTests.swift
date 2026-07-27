import XCTest
@testable import PRBar

/// End-to-end over the worker's staging path: what a completed review
/// turns into (an approval with no body, a request-changes with the
/// summary, a flag that posts nothing) and what actually reaches the
/// write queue when the batch fires.
@MainActor
final class AutoReviewStagingTests: XCTestCase {
    /// One captured `enqueueAutoReview` call.
    private struct Posted: Equatable {
        let nodeId: String
        let kind: ReviewActionKind
        let body: String
        let comments: [GHClient.InlineComment]
    }

    func testApproveStagesWithNoBodyByDefault() async throws {
        let worker = makeWorker(
            provider: StubProvider(verdict: .approve, summary: "looks fine", cost: 0.02),
            config: config(approve: enabledApprove())
        )
        worker.enqueue(makePR())
        try await waitForStaged(worker)

        let staged = try XCTUnwrap(worker.pendingAutoActions["PR_1"])
        XCTAssertEqual(staged.action, .approve)
        XCTAssertEqual(staged.body, "", "the attribution comment is opt-in — a bare approval is the default")
        XCTAssertTrue(staged.comments.isEmpty)
    }

    func testApproveAttributionCommentIsOptIn() async throws {
        var approve = enabledApprove()
        approve.postAttributionComment = true
        let worker = makeWorker(
            provider: StubProvider(verdict: .approve, summary: "looks fine", cost: 0.02, confidence: 0.93),
            config: config(approve: approve)
        )
        worker.enqueue(makePR())
        try await waitForStaged(worker)

        let staged = try XCTUnwrap(worker.pendingAutoActions["PR_1"])
        XCTAssertTrue(staged.body.hasPrefix("Auto-approved by PRBar"), "got body: \(staged.body)")
        XCTAssertTrue(staged.body.contains("93%"), "got body: \(staged.body)")
    }

    func testApproveInlineAnnotationsAreOptIn() async throws {
        let annotation = DiffAnnotation(
            path: "a", lineStart: 1, lineEnd: 1, severity: .info,
            title: "Nit", body: "consider renaming"
        )
        var approve = enabledApprove()
        approve.postInlineAnnotations = true
        let worker = makeWorker(
            provider: StubProvider(verdict: .approve, summary: "fine", cost: 0.02, annotations: [annotation]),
            config: config(approve: approve)
        )
        worker.enqueue(makePR())
        try await waitForStaged(worker)

        let staged = try XCTUnwrap(worker.pendingAutoActions["PR_1"])
        XCTAssertEqual(staged.comments.count, 1)
        XCTAssertEqual(staged.comments.first?.path, "a")
        XCTAssertEqual(staged.comments.first?.line, 1)
    }

    /// An annotation pointing outside the diff can't be posted — GitHub
    /// 422s the whole review if one entry is off-diff.
    func testOffDiffAnnotationsAreDropped() async throws {
        let offDiff = DiffAnnotation(
            path: "somewhere/else.go", lineStart: 40, lineEnd: 40,
            severity: .warning, title: "x", body: "y"
        )
        var approve = enabledApprove()
        approve.postInlineAnnotations = true
        approve.maxAnnotationSeverity = .warning
        let worker = makeWorker(
            provider: StubProvider(verdict: .approve, summary: "fine", cost: 0.02, annotations: [offDiff]),
            config: config(approve: approve)
        )
        worker.enqueue(makePR())
        try await waitForStaged(worker)

        XCTAssertTrue(try XCTUnwrap(worker.pendingAutoActions["PR_1"]).comments.isEmpty)
    }

    func testFlagOnlyDenialNeverStagesAPost() async throws {
        let annotation = DiffAnnotation(
            path: "a", lineStart: 1, lineEnd: 1, severity: .blocker,
            title: "Boom", body: "this crashes"
        )
        let worker = makeWorker(
            provider: StubProvider(verdict: .requestChanges, summary: "no", cost: 0.02, annotations: [annotation]),
            config: config(deny: AutoDenyConfig(action: .flagOnly))
        )
        var posted: [Posted] = []
        worker.enqueueAutoReview = { pr, kind, body, comments, _ in
            posted.append(Posted(nodeId: pr.nodeId, kind: kind, body: body, comments: comments))
        }

        worker.enqueue(makePR())
        try await waitUntil { worker.flaggedDenials["PR_1"] != nil }

        XCTAssertTrue(worker.pendingAutoActions.isEmpty, "flag-only must never enter the post batch")
        XCTAssertFalse(worker.batchUndoActive, "no countdown for something that never posts")

        // Even if the batch is fired by hand, nothing goes out.
        worker.fireAutoReviewBatchNow()
        XCTAssertTrue(posted.isEmpty)

        worker.dismissFlaggedDenial("PR_1")
        XCTAssertTrue(worker.flaggedDenials.isEmpty)
    }

    func testRequestChangesPostsSummaryAsBody() async throws {
        let annotation = DiffAnnotation(
            path: "a", lineStart: 1, lineEnd: 1, severity: .blocker,
            title: "Boom", body: "this crashes"
        )
        let worker = makeWorker(
            provider: StubProvider(
                verdict: .requestChanges, summary: "This breaks the cache.",
                cost: 0.02, annotations: [annotation]
            ),
            config: config(deny: AutoDenyConfig(action: .requestChanges))
        )
        var posted: [Posted] = []
        worker.enqueueAutoReview = { pr, kind, body, comments, _ in
            posted.append(Posted(nodeId: pr.nodeId, kind: kind, body: body, comments: comments))
        }

        worker.enqueue(makePR())
        try await waitForStaged(worker)
        worker.fireAutoReviewBatchNow()

        XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(posted.first?.kind, .requestChanges)
        // GitHub rejects an empty body on REQUEST_CHANGES, so the summary
        // has to carry it.
        XCTAssertEqual(posted.first?.body, "This breaks the cache.")
        XCTAssertEqual(posted.first?.comments.count, 1)
        XCTAssertTrue(worker.pendingAutoActions.isEmpty)
        XCTAssertFalse(worker.batchUndoActive)
    }

    func testUndoDiscardsTheBatch() async throws {
        let worker = makeWorker(
            provider: StubProvider(verdict: .approve, summary: "fine", cost: 0.02),
            config: config(approve: enabledApprove())
        )
        var posted: [Posted] = []
        worker.enqueueAutoReview = { pr, kind, body, comments, _ in
            posted.append(Posted(nodeId: pr.nodeId, kind: kind, body: body, comments: comments))
        }

        worker.enqueue(makePR())
        try await waitForStaged(worker)
        worker.cancelAutoReviewBatch()
        worker.fireAutoReviewBatchNow()

        XCTAssertTrue(posted.isEmpty)
        XCTAssertTrue(worker.pendingAutoActions.isEmpty)
    }

    func testNothingStagesWhenBothSidesAreOff() async throws {
        let worker = makeWorker(
            provider: StubProvider(verdict: .approve, summary: "fine", cost: 0.02),
            config: RepoConfig.default
        )
        worker.enqueue(makePR())
        try await waitUntil {
            if case .completed = worker.reviews["PR_1"]?.status { return true }
            return false
        }

        XCTAssertTrue(worker.pendingAutoActions.isEmpty)
        XCTAssertTrue(worker.flaggedDenials.isEmpty)
        XCTAssertFalse(worker.batchUndoActive)
    }

    // MARK: - helpers

    private func enabledApprove() -> AutoApproveConfig {
        AutoApproveConfig(enabled: true, minConfidence: 0.85, maxAdditions: 0)
    }

    private func config(
        approve: AutoApproveConfig = .off,
        deny: AutoDenyConfig = .off
    ) -> RepoConfig {
        var cfg = RepoConfig.default
        cfg.autoApprove = approve
        cfg.autoDeny = deny
        return cfg
    }

    /// `configResolver` is `@Sendable`, so the closure can't capture
    /// `self` — the config is copied into a local first.
    private func makeWorker(provider: ReviewProvider, config: RepoConfig) -> ReviewQueueWorker {
        let w = ReviewQueueWorker(diffFetcher: { _, _, _ in
            "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-x\n+y\n"
        })
        w.provider = provider
        w.providerLookup = nil
        let resolved = config
        w.configResolver = { _, _ in resolved }
        return w
    }

    private func makePR() -> InboxPR {
        InboxPR(
            nodeId: "PR_1", owner: "o", repo: "r", number: 1,
            title: "t", body: "", url: URL(string: "https://github.com/o/r/pull/1")!,
            author: "a", headRef: "h", baseRef: "main",
            headSha: "abc123", isDraft: false,
            role: .reviewRequested,
            mergeable: "MERGEABLE", mergeStateStatus: "BLOCKED", reviewDecision: nil,
            checkRollupState: "EMPTY",
            totalAdditions: 1, totalDeletions: 0, changedFiles: 1,
            hasAutoMerge: false, autoMergeEnabledBy: nil, allCheckSummaries: [],
            allowedMergeMethods: [.squash], autoMergeAllowed: false, deleteBranchOnMerge: false
        )
    }

    private func waitForStaged(_ worker: ReviewQueueWorker) async throws {
        try await waitUntil { worker.pendingAutoActions["PR_1"] != nil }
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeout.components.seconds))
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
