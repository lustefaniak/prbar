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
        return w
    }

    private func makePR(nodeId: String, number: Int, role: PRRole = .reviewRequested) -> InboxPR {
        InboxPR(
            nodeId: nodeId, owner: "o", repo: "r", number: number,
            title: "t", body: "", url: URL(string: "https://github.com/o/r/pull/\(number)")!,
            author: "a", headRef: "h", baseRef: "main", isDraft: false,
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

    func review(bundle: PromptBundle, options: ProviderOptions) async throws -> ProviderResult {
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

    func review(bundle: PromptBundle, options: ProviderOptions) async throws -> ProviderResult {
        callCount += 1
        try await Task.sleep(for: .milliseconds(80))
        return ProviderResult(
            verdict: verdict, confidence: 0.8, summaryMarkdown: "slow",
            annotations: [], costUsd: 0.02, toolCallCount: 0, toolNamesUsed: [],
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

    func review(bundle: PromptBundle, options: ProviderOptions) async throws -> ProviderResult {
        throw error
    }
}
