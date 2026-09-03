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
        worker.enqueueAutoReview = { pr, kind, body, comments, _, _ in
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
        worker.enqueueAutoReview = { pr, kind, body, comments, _, _ in
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
        worker.enqueueAutoReview = { pr, kind, body, comments, _, _ in
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

    // MARK: - share

    /// The whole point of the feature: with both gates off, a completed
    /// review still reaches the author — as a comment, never a verdict.
    func testShareStagesACommentWithTheFindingsInline() async throws {
        let warning = DiffAnnotation(
            path: "a", lineStart: 1, lineEnd: 1, severity: .warning,
            title: "Unchecked nil", body: "this can crash"
        )
        let worker = makeWorker(
            provider: StubProvider(
                verdict: .approve, summary: "one thing to fix", cost: 0.02,
                annotations: [warning]
            ),
            config: config(share: .warningsAndBlockers)
        )
        worker.enqueue(makePR())
        try await waitForStaged(worker)

        let staged = try XCTUnwrap(worker.pendingAutoActions["PR_1"])
        XCTAssertEqual(staged.action, .comment, "sharing must never cast a verdict")
        XCTAssertEqual(
            staged.body, "one thing to fix",
            "a shared review reads like any other PRBar review — no banner, no disclaimer"
        )
        XCTAssertEqual(staged.comments.count, 1)
        XCTAssertEqual(
            staged.source, .sharedFindings,
            "the source is the only thing distinguishing this from an auto-deny comment"
        )
    }

    /// A share and an auto-deny comment post the identical GitHub event
    /// with the identical body shape, so History can only tell them apart
    /// by the log kind the source resolves to.
    func testShareIsLoggedAsItsOwnHistoryKind() async throws {
        let warning = DiffAnnotation(
            path: "a", lineStart: 1, lineEnd: 1, severity: .warning,
            title: "Unchecked nil", body: "this can crash"
        )
        let log = ActionLogStore(container: PRBarModelContainer.inMemory())
        let worker = makeWorker(
            provider: StubProvider(
                verdict: .approve, summary: "one thing to fix", cost: 0.02,
                annotations: [warning]
            ),
            config: config(share: .warningsAndBlockers)
        )
        worker.actionLog = log
        worker.undoWindow = 0.01
        worker.enqueue(makePR())
        try await waitForStaged(worker)
        worker.fireAutoReviewBatchNow()

        try await waitUntil { !log.fetchAll().isEmpty }
        let kinds: [ActionLogKind] = log.fetchAll().map(\.kind)
        XCTAssertEqual(kinds, [.autoShare],
                       "an auto-deny comment would land as .autoComment")
    }

    /// A policy of "warnings and blockers" that still posts every nitpick
    /// inline would contradict the setting the user picked.
    func testShareDropsAnnotationsBelowTheFloor() async throws {
        let warning = DiffAnnotation(
            path: "a", lineStart: 1, lineEnd: 1, severity: .warning,
            title: "Unchecked nil", body: "this can crash"
        )
        let nit = DiffAnnotation(
            path: "a", lineStart: 1, lineEnd: 1, severity: .info,
            title: "Nit", body: "rename this"
        )
        let worker = makeWorker(
            provider: StubProvider(
                verdict: .approve, summary: "s", cost: 0.02,
                annotations: [warning, nit]
            ),
            config: config(share: .warningsAndBlockers)
        )
        worker.enqueue(makePR())
        try await waitForStaged(worker)

        let staged = try XCTUnwrap(worker.pendingAutoActions["PR_1"])
        XCTAssertEqual(staged.comments.count, 1, "the info annotation is below the floor")
    }

    /// Neither the severity floor nor any diff-size cap bounds how many
    /// inline comments a share posts. Without this, a large PR that
    /// legitimately earns 200 findings floods the author's PR.
    func testShareCapsInlineCommentsAndKeepsTheWorstOnes() async throws {
        let blocker = DiffAnnotation(
            path: "a", lineStart: 1, lineEnd: 1, severity: .blocker,
            title: "Boom", body: "crashes"
        )
        let warnings = (0..<5).map { i in
            DiffAnnotation(
                path: "a", lineStart: 1, lineEnd: 1, severity: .warning,
                title: "W\(i)", body: "b"
            )
        }
        let worker = makeWorker(
            provider: StubProvider(
                verdict: .approve, summary: "s", cost: 0.02,
                annotations: warnings + [blocker]
            ),
            config: config(share: .warningsAndBlockers, shareMaxComments: 2)
        )
        worker.enqueue(makePR())
        try await waitForStaged(worker)

        let staged = try XCTUnwrap(worker.pendingAutoActions["PR_1"])
        XCTAssertEqual(staged.comments.count, 2)
        XCTAssertTrue(
            staged.comments.contains { $0.body.contains("Boom") },
            "a cap that drops the blocker to keep nitpicks is worse than no cap"
        )
    }

    // MARK: - thread resolution

    private func warningAnnotation() -> DiffAnnotation {
        DiffAnnotation(
            path: "a", lineStart: 1, lineEnd: 1, severity: .warning,
            title: "Unchecked nil", body: "this can crash"
        )
    }

    /// `nonisolated static` because `reviewThreadFetcher` is `@Sendable`
    /// and can't capture the (MainActor-isolated, non-Sendable) test case.
    private nonisolated static func threadPage(headRefOid: String) -> ReviewThreadPage {
        ReviewThreadPage(
            threads: [ReviewThread(
                id: "T1", isResolved: false, isOutdated: true, path: "a",
                comments: [
                    .init(authorLogin: "me", body: "**Old finding**\n\nx\n\n\(InlineCommentMapper.provenanceMarker)"),
                    .init(authorLogin: "a", body: "fixed"),
                ]
            )],
            viewerLogin: "me",
            headRefOid: headRefOid
        )
    }

    /// Ships off. Resolving collapses a thread for every human on the PR,
    /// so a user who never asked for it must never get it.
    func testThreadsAreNotResolvedUnlessTheRepoOptedIn() async throws {
        let worker = makeWorker(
            provider: StubProvider(verdict: .approve, summary: "s", cost: 0.01, annotations: []),
            config: config()
        )
        let fetches = FetchCounter()
        worker.reviewThreadFetcher = { _, _, _ in
            fetches.bump()
            return Self.threadPage(headRefOid: "abc123")
        }
        var queued: [[String]] = []
        worker.enqueueResolveThreads = { _, ids in queued.append(ids) }

        worker.enqueue(makePR())
        try await waitUntil { worker.reviews["PR_1"]?.status.isTerminal == true }

        XCTAssertEqual(fetches.count, 0, "the opt-out path must not even fetch")
        XCTAssertTrue(queued.isEmpty)
    }

    func testThreadsResolveWhenEnabled() async throws {
        var cfg = config()
        cfg.resolveThreads = ResolveThreadsConfig(enabled: true, minConfidence: 0.5)
        let worker = makeWorker(
            provider: StubProvider(verdict: .approve, summary: "s", cost: 0.01, annotations: []),
            config: cfg
        )
        worker.reviewThreadFetcher = { _, _, _ in Self.threadPage(headRefOid: "abc123") }
        var queued: [[String]] = []
        worker.enqueueResolveThreads = { _, ids in queued.append(ids) }

        worker.enqueue(makePR())
        try await waitUntil { !queued.isEmpty }
        XCTAssertEqual(queued, [["T1"]])
    }

    /// The findings describe the commit the triage ran on, but `isOutdated`
    /// is read live. A push landing mid-review would otherwise let stale
    /// findings close threads on code nobody has looked at.
    func testThreadsAreNotResolvedWhenTheHeadMovedMidReview() async throws {
        var cfg = config()
        cfg.resolveThreads = ResolveThreadsConfig(enabled: true, minConfidence: 0.5)
        let worker = makeWorker(
            provider: StubProvider(verdict: .approve, summary: "s", cost: 0.01, annotations: []),
            config: cfg
        )
        worker.reviewThreadFetcher = { _, _, _ in Self.threadPage(headRefOid: "deadbee") }
        var queued: [[String]] = []
        worker.enqueueResolveThreads = { _, ids in queued.append(ids) }

        worker.enqueue(makePR())
        try await waitUntil { worker.reviews["PR_1"]?.status.isTerminal == true }
        XCTAssertTrue(queued.isEmpty, "reviewed abc123, threads read against deadbee")
    }

    /// A thread closes because a finding is *absent*, which is exactly what
    /// a degraded run produces. The floor is what keeps one from closing
    /// every open thread on the PR.
    func testLowConfidenceTriageResolvesNothing() async throws {
        var cfg = config()
        cfg.resolveThreads = ResolveThreadsConfig(enabled: true, minConfidence: 0.85)
        let worker = makeWorker(
            // The shape of a degraded run: a placeholder summary, no
            // annotations, and confidence the model doesn't stand behind.
            provider: StubProvider(
                verdict: .approve, summary: "test", cost: 0.01,
                annotations: [], confidence: 0.2
            ),
            config: cfg
        )
        worker.reviewThreadFetcher = { _, _, _ in Self.threadPage(headRefOid: "abc123") }
        var queued: [[String]] = []
        worker.enqueueResolveThreads = { _, ids in queued.append(ids) }

        worker.enqueue(makePR())
        try await waitUntil { worker.reviews["PR_1"]?.status.isTerminal == true }
        XCTAssertTrue(queued.isEmpty)
    }

    private func enabledApprove() -> AutoApproveConfig {
        AutoApproveConfig(enabled: true, minConfidence: 0.85, maxAdditions: 0)
    }

    private func config(
        approve: AutoApproveConfig = .off,
        deny: AutoDenyConfig = .off,
        share: ShareFindingsPolicy = .off,
        shareMaxComments: Int = 0
    ) -> RepoConfig {
        var cfg = RepoConfig.default
        cfg.autoApprove = approve
        cfg.autoDeny = deny
        cfg.shareFindings = share
        cfg.shareMaxComments = shareMaxComments
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
        let resolved = config.resolved()
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

/// Sendable counter for assertions made from inside a `@Sendable` closure.
private final class FetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
