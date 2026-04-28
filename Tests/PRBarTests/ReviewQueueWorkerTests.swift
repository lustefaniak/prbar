import XCTest
@testable import PRBar

@MainActor
final class ReviewQueueWorkerTests: XCTestCase {
    func testEnqueueRunsReviewAndStoresResult() async throws {
        let pr = makePR(nodeId: "PR_1", number: 1)
        let stubProvider = StubProvider(verdict: .approve, summary: "ok", cost: 0.05)
        let worker = makeWorker(provider: stubProvider, diffText: makeDiff())

        worker.enqueue(pr)
        try await waitUntil { self.isCompleted(worker.reviews["PR_1"]?.status) }

        guard case .completed(let agg) = worker.reviews["PR_1"]?.status else {
            return XCTFail("expected .completed")
        }
        XCTAssertEqual(agg.verdict, .approve)
        XCTAssertEqual(agg.summaryMarkdown, "ok")
        XCTAssertEqual(worker.reviews["PR_1"]?.costUsd ?? 0, 0.05, accuracy: 1e-9)
        XCTAssertEqual(stubProvider.callCount, 1)
    }

    func testEnqueueIsIdempotentForInFlightPR() async throws {
        let pr = makePR(nodeId: "PR_1", number: 1)
        let stubProvider = SlowStubProvider(verdict: .comment)
        let worker = makeWorker(provider: stubProvider, diffText: makeDiff())

        worker.enqueue(pr)
        worker.enqueue(pr)   // second call is no-op while first is queued/running
        worker.enqueue(pr)

        try await waitUntil { self.isCompleted(worker.reviews["PR_1"]?.status) }

        XCTAssertEqual(stubProvider.callCount, 1, "duplicate enqueues should not re-run")
    }

    func testRetriageOnSHAChangeCapturesPriorReview() async throws {
        let provider = StubProvider(verdict: .comment, summary: "first", cost: 0.05)
        let worker = makeWorker(provider: provider, diffText: makeDiff())

        // First triage on old SHA.
        let oldPR = makePR(nodeId: "PR_1", number: 1, headSha: "oldSha1")
        worker.enqueue(oldPR)
        try await waitUntil { self.isCompleted(worker.reviews["PR_1"]?.status) }
        XCTAssertNil(worker.reviews["PR_1"]?.priorReview,
            "first triage shouldn't have a priorReview yet")

        // PR head moves — re-enqueue with a slow provider so we can
        // observe the .running state while priorReview is attached.
        let newPR = makePR(nodeId: "PR_1", number: 1, headSha: "newSha2")
        let slow = SlowStubProvider(verdict: .approve)
        worker.provider = slow
        worker.enqueue(newPR)

        try await waitUntil {
            if case .running = worker.reviews["PR_1"]?.status { return true }
            return false
        }
        XCTAssertEqual(worker.reviews["PR_1"]?.priorReview?.headSha, "oldSha1")
        XCTAssertEqual(worker.reviews["PR_1"]?.priorReview?.aggregated.summaryMarkdown, "first")
        XCTAssertEqual(worker.reviews["PR_1"]?.headSha, "newSha2")

        try await waitUntil { self.isCompleted(worker.reviews["PR_1"]?.status) }
        XCTAssertNil(worker.reviews["PR_1"]?.priorReview,
            "successful retriage should clear the priorReview")
    }

    func testForceFullReviewDropsPriorReviewFromPromptOnRetriage() async throws {
        // First triage on old SHA captures a normal prior review.
        let provider = BundleCapturingStubProvider(verdict: .comment, summary: "first", cost: 0.01)
        let worker = makeWorker(provider: provider, diffText: makeDiff())
        // Repo opts into "always do a full review" — retriage should NOT
        // carry the prior verdict into the prompt or the ReviewState.
        worker.configResolver = { _, _ in
            var c = RepoConfig.default
            c.forceFullReview = true
            return c
        }

        let oldPR = makePR(nodeId: "PR_F", number: 7, headSha: "oldShaA")
        worker.enqueue(oldPR)
        try await waitUntil { self.isCompleted(worker.reviews["PR_F"]?.status) }

        // PR head moves → retriage. With forceFullReview the prior should
        // be dropped before it ever reaches the prompt or ReviewState.
        let newPR = makePR(nodeId: "PR_F", number: 7, headSha: "newShaB")
        worker.enqueue(newPR)
        try await waitUntil { self.isCompleted(worker.reviews["PR_F"]?.status) }

        XCTAssertNil(worker.reviews["PR_F"]?.priorReview,
            "forceFullReview should suppress priorReview on the new entry")
        XCTAssertEqual(provider.callCount, 2, "retriage should still run the provider")
        let lastPrompt = provider.lastUserPrompt ?? ""
        XCTAssertFalse(lastPrompt.contains("## Previous review"),
            "forceFullReview prompt must omit the prior-review section")
    }

    func testProviderResolutionPriorityPerRunOverridesRepoOverridesDefault() async throws {
        // Build a worker whose providerLookup returns ID-tagged stubs so
        // we can assert which one ran for each scenario.
        let recorder = ProviderCallRecorder()
        let worker = makeWorker(
            provider: StubProvider(verdict: .approve, summary: "default", cost: 0),
            diffText: makeDiff()
        )
        worker.providerLookup = { id in
            recorder.lastUsed = id
            return StubProvider(verdict: .approve, summary: id.rawValue, cost: 0)
        }
        worker.defaultProviderId = .claude

        // 1. No overrides → app default (claude).
        worker.configResolver = { _, _ in RepoConfig.default }
        worker.enqueue(makePR(nodeId: "P1", number: 1))
        try await waitUntil { self.isCompleted(worker.reviews["P1"]?.status) }
        XCTAssertEqual(recorder.lastUsed, .claude)
        XCTAssertEqual(worker.reviews["P1"]?.providerId, .claude)

        // 2. Repo override = codex → codex.
        worker.configResolver = { _, _ in
            var c = RepoConfig.default
            c.providerOverride = .codex
            return c
        }
        worker.enqueue(makePR(nodeId: "P2", number: 2))
        try await waitUntil { self.isCompleted(worker.reviews["P2"]?.status) }
        XCTAssertEqual(recorder.lastUsed, .codex)
        XCTAssertEqual(worker.reviews["P2"]?.providerId, .codex)

        // 3. Repo says codex but per-run override = claude → claude wins.
        worker.enqueue(makePR(nodeId: "P3", number: 3), providerOverride: .claude)
        try await waitUntil { self.isCompleted(worker.reviews["P3"]?.status) }
        XCTAssertEqual(recorder.lastUsed, .claude,
            "per-run override should beat repo override")
        XCTAssertEqual(worker.reviews["P3"]?.providerId, .claude)
    }

    func testForceReRunReevaluatesCompletedPR() async throws {
        let pr = makePR(nodeId: "PR_1", number: 1)
        let stubProvider = StubProvider(verdict: .approve, summary: "first", cost: 0.05)
        let worker = makeWorker(provider: stubProvider, diffText: makeDiff())

        worker.enqueue(pr)
        try await waitUntil { self.isCompleted(worker.reviews["PR_1"]?.status) }
        XCTAssertEqual(stubProvider.callCount, 1)

        stubProvider.summary = "second"
        worker.enqueue(pr, force: true)
        try await waitUntil {
            if case .completed(let agg) = worker.reviews["PR_1"]?.status {
                return agg.summaryMarkdown == "second"
            }
            return false
        }
        XCTAssertEqual(stubProvider.callCount, 2, "force re-run should call the provider again")
    }

    func testFailureSurfacedAsFailedStatus() async throws {
        let pr = makePR(nodeId: "PR_1", number: 1)
        let stubProvider = ThrowingStubProvider(error: TestError.boom)
        let worker = makeWorker(provider: stubProvider, diffText: makeDiff())

        worker.enqueue(pr)
        try await waitUntil { self.isFailed(worker.reviews["PR_1"]?.status) }

        if case .failed(let msg) = worker.reviews["PR_1"]?.status {
            XCTAssertTrue(msg.contains("boom"))
        } else {
            XCTFail("expected .failed")
        }
    }

    func testEmptyDiffYieldsFailedStatus() async throws {
        let pr = makePR(nodeId: "PR_1", number: 1)
        let stubProvider = StubProvider(verdict: .approve, summary: "x", cost: 0)
        let worker = makeWorker(provider: stubProvider, diffText: "")

        worker.enqueue(pr)
        try await waitUntil { self.isFailed(worker.reviews["PR_1"]?.status) }

        if case .failed(let msg) = worker.reviews["PR_1"]?.status {
            XCTAssertTrue(msg.lowercased().contains("empty diff"))
        }
    }

    func testEnqueueNewReviewRequestsOnlyEnqueuesReviewerRoles() async throws {
        let prs = [
            makePR(nodeId: "A", number: 1, role: .authored),
            makePR(nodeId: "B", number: 2, role: .reviewRequested),
            makePR(nodeId: "C", number: 3, role: .both),
            makePR(nodeId: "D", number: 4, role: .other),
        ]
        let provider = StubProvider(verdict: .approve, summary: "x", cost: 0.05)
        let worker = makeWorker(provider: provider, diffText: makeDiff())

        worker.enqueueNewReviewRequests(from: prs)
        try await waitUntil {
            self.isCompleted(worker.reviews["B"]?.status)
                && self.isCompleted(worker.reviews["C"]?.status)
        }

        XCTAssertNil(worker.reviews["A"], "authored PR should not be enqueued")
        XCTAssertNil(worker.reviews["D"], ".other PR should not be enqueued")
        XCTAssertNotNil(worker.reviews["B"])
        XCTAssertNotNil(worker.reviews["C"])
    }

    func testDailyCostCapBlocksEnqueue() async throws {
        let pr1 = makePR(nodeId: "A", number: 1)
        let pr2 = makePR(nodeId: "B", number: 2)
        let provider = StubProvider(verdict: .approve, summary: "x", cost: 5.0)   // each costs $5
        let worker = makeWorker(provider: provider, diffText: makeDiff())
        worker.dailyCostCap = 5.0

        worker.enqueue(pr1)
        try await waitUntil { self.isCompleted(worker.reviews["A"]?.status) }

        worker.enqueue(pr2)   // cumulativeSpend == 5.0, cap == 5.0 — should refuse
        if case .failed(let msg) = worker.reviews["B"]?.status {
            XCTAssertTrue(msg.contains("cap reached"))
        } else {
            XCTFail("PR2 should have been blocked by daily cap")
        }
    }

    // MARK: - helpers

    private func makeWorker(provider: ReviewProvider, diffText: String) -> ReviewQueueWorker {
        let w = ReviewQueueWorker(diffFetcher: { _, _, _ in diffText })
        w.provider = provider
        // Clear the production providerLookup so the legacy single-stub
        // path (worker.provider = stub) drives the run; tests that
        // exercise per-ID dispatch re-set this themselves.
        w.providerLookup = nil
        return w
    }

    private func makePR(
        nodeId: String,
        number: Int,
        role: PRRole = .reviewRequested,
        headSha: String = "abc123"
    ) -> InboxPR {
        InboxPR(
            nodeId: nodeId, owner: "o", repo: "r", number: number,
            title: "t", body: "", url: URL(string: "https://github.com/o/r/pull/\(number)")!,
            author: "a", headRef: "h", baseRef: "main",
            headSha: headSha, isDraft: false,
            role: role,
            mergeable: "MERGEABLE", mergeStateStatus: "BLOCKED", reviewDecision: nil,
            checkRollupState: "EMPTY",
            totalAdditions: 1, totalDeletions: 0, changedFiles: 1,
            hasAutoMerge: false, autoMergeEnabledBy: nil, allCheckSummaries: [],
            allowedMergeMethods: [.squash], autoMergeAllowed: false, deleteBranchOnMerge: false
        )
    }

    private func makeDiff() -> String {
        "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-x\n+y\n"
    }

    private func isCompleted(_ status: ReviewState.Status?) -> Bool {
        if case .completed = status { return true }
        return false
    }

    private func isFailed(_ status: ReviewState.Status?) -> Bool {
        if case .failed = status { return true }
        return false
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeout.components.seconds))
        while !condition() {
            if Date() > deadline {
                XCTFail("waitUntil timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

// MARK: - test stubs

private enum TestError: Error, LocalizedError {
    case boom
    var errorDescription: String? { "boom" }
}

private final class StubProvider: ReviewProvider, @unchecked Sendable {
    var id: String { "stub" }
    var displayName: String { "Stub" }

    var verdict: ReviewVerdict
    var summary: String
    var cost: Double
    private(set) var callCount: Int = 0

    init(verdict: ReviewVerdict, summary: String, cost: Double) {
        self.verdict = verdict
        self.summary = summary
        self.cost = cost
    }

    func availability() async -> ProviderAvailability { .ready }

    func review(
        bundle: PromptBundle,
        options: ProviderOptions,
        onProgress: (@Sendable (ReviewProgress) -> Void)?
    ) async throws -> ProviderResult {
        callCount += 1
        return ProviderResult(
            verdict: verdict, confidence: 0.9, summaryMarkdown: summary,
            annotations: [], costUsd: cost, toolCallCount: 0, toolNamesUsed: [],
            rawJson: Data()
        )
    }
}

private final class SlowStubProvider: ReviewProvider, @unchecked Sendable {
    var id: String { "slow-stub" }
    var displayName: String { "SlowStub" }
    let verdict: ReviewVerdict
    private(set) var callCount: Int = 0

    init(verdict: ReviewVerdict) { self.verdict = verdict }

    func availability() async -> ProviderAvailability { .ready }

    func review(
        bundle: PromptBundle,
        options: ProviderOptions,
        onProgress: (@Sendable (ReviewProgress) -> Void)?
    ) async throws -> ProviderResult {
        callCount += 1
        // Emit a progress event so workers wiring liveProgress have
        // something to observe during the in-flight window.
        onProgress?(ReviewProgress(toolCallCount: 1, toolNamesUsed: ["Read"], costUsdSoFar: nil, lastAssistantText: nil))
        try await Task.sleep(for: .milliseconds(80))
        return ProviderResult(
            verdict: verdict, confidence: 0.8, summaryMarkdown: "slow",
            annotations: [], costUsd: 0.02, toolCallCount: 0, toolNamesUsed: [],
            rawJson: Data()
        )
    }
}

/// Tracks which `ProviderID` the worker dispatched to. Used by the
/// provider-resolution priority test. `@unchecked Sendable` since the
/// providerLookup closure isn't main-actor-isolated; we only ever
/// touch this from MainActor in the tests anyway.
private final class ProviderCallRecorder: @unchecked Sendable {
    var lastUsed: ProviderID?
}

/// Like `StubProvider` but retains the most recent `bundle.userPrompt` so
/// tests can assert what the assembler actually sent to the model.
private final class BundleCapturingStubProvider: ReviewProvider, @unchecked Sendable {
    var id: String { "capture-stub" }
    var displayName: String { "CaptureStub" }

    var verdict: ReviewVerdict
    var summary: String
    var cost: Double
    private(set) var callCount: Int = 0
    private(set) var lastUserPrompt: String?

    init(verdict: ReviewVerdict, summary: String, cost: Double) {
        self.verdict = verdict
        self.summary = summary
        self.cost = cost
    }

    func availability() async -> ProviderAvailability { .ready }

    func review(
        bundle: PromptBundle,
        options: ProviderOptions,
        onProgress: (@Sendable (ReviewProgress) -> Void)?
    ) async throws -> ProviderResult {
        callCount += 1
        lastUserPrompt = bundle.userPrompt
        return ProviderResult(
            verdict: verdict, confidence: 0.9, summaryMarkdown: summary,
            annotations: [], costUsd: cost, toolCallCount: 0, toolNamesUsed: [],
            rawJson: Data()
        )
    }
}

private final class ThrowingStubProvider: ReviewProvider, @unchecked Sendable {
    var id: String { "throw-stub" }
    var displayName: String { "ThrowStub" }
    let error: Error

    init(error: Error) { self.error = error }

    func availability() async -> ProviderAvailability { .ready }

    func review(
        bundle: PromptBundle,
        options: ProviderOptions,
        onProgress: (@Sendable (ReviewProgress) -> Void)?
    ) async throws -> ProviderResult {
        throw error
    }
}
