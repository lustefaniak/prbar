import XCTest
@testable import PRBar

@MainActor
final class ReviewQueueWorkerLoggingTests: XCTestCase {
    func testCompletedTriageAppendsToReviewLog() async throws {
        let log = ReviewLogStore(container: PRBarModelContainer.inMemory())
        let worker = makeWorker(reviewLog: log, diffText: makeDiff())
        worker.provider = StubProvider(verdict: .comment, summary: "ok", cost: 0.07)

        worker.enqueue(makePR())
        try await waitUntil { self.isCompleted(worker.reviews["PR_1"]?.status) }

        let rows = log.fetchAll()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].status, .completed)
        XCTAssertEqual(rows[0].verdict, .comment)
        XCTAssertEqual(rows[0].costUsd ?? 0, 0.07, accuracy: 1e-9)
        XCTAssertEqual(rows[0].providerId, .claude)
        XCTAssertEqual(rows[0].decodeAggregated()?.summaryMarkdown, "ok")
    }

    func testFailedTriageAppendsFailureRow() async throws {
        let log = ReviewLogStore(container: PRBarModelContainer.inMemory())
        let worker = makeWorker(reviewLog: log, diffText: makeDiff())
        worker.provider = ThrowingStubProvider(error: TestError.boom)

        worker.enqueue(makePR())
        try await waitUntil { self.isFailed(worker.reviews["PR_1"]?.status) }

        let rows = log.fetchAll()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].status, .failed)
        XCTAssertNotNil(rows[0].errorMessage)
        XCTAssertNil(rows[0].verdict)
    }

    func testEmptyDiffAppendsFailureRow() async throws {
        let log = ReviewLogStore(container: PRBarModelContainer.inMemory())
        let worker = makeWorker(reviewLog: log, diffText: "")
        worker.provider = StubProvider(verdict: .approve, summary: "x", cost: 0)

        worker.enqueue(makePR())
        try await waitUntil { self.isFailed(worker.reviews["PR_1"]?.status) }

        let rows = log.fetchAll()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].status, .failed)
        XCTAssertEqual(rows[0].errorMessage?.lowercased().contains("empty diff"), true)
    }

    func testCapBlockedEnqueueAppendsFailureRow() async throws {
        let log = ReviewLogStore(container: PRBarModelContainer.inMemory())
        let worker = makeWorker(reviewLog: log, diffText: makeDiff())
        worker.provider = StubProvider(verdict: .approve, summary: "x", cost: 5.0)
        worker.dailyCostCap = 5.0

        worker.enqueue(makePR("A", number: 1))
        try await waitUntil { self.isCompleted(worker.reviews["A"]?.status) }

        worker.enqueue(makePR("B", number: 2))
        // cap-blocked path is synchronous in enqueue
        XCTAssertTrue(self.isFailed(worker.reviews["B"]?.status))

        let rows = log.fetchAll().sorted { $0.prNumber < $1.prNumber }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].status, .completed)
        XCTAssertEqual(rows[1].status, .failed)
        XCTAssertEqual(rows[1].errorMessage?.contains("cap reached"), true)
    }

    func testCumulativeSpendUsesLogWhenWired() async throws {
        let log = ReviewLogStore(container: PRBarModelContainer.inMemory())
        let worker = makeWorker(reviewLog: log, diffText: makeDiff())
        worker.provider = StubProvider(verdict: .approve, summary: "x", cost: 0.10)

        worker.enqueue(makePR("A", number: 1))
        try await waitUntil { self.isCompleted(worker.reviews["A"]?.status) }
        XCTAssertEqual(worker.cumulativeSpend(), 0.10, accuracy: 1e-9)

        worker.provider = StubProvider(verdict: .approve, summary: "y", cost: 0.20)
        worker.enqueue(makePR("B", number: 2))
        try await waitUntil { self.isCompleted(worker.reviews["B"]?.status) }
        XCTAssertEqual(worker.cumulativeSpend(), 0.30, accuracy: 1e-9,
                       "spend tally is the sum of today's log rows, not the in-memory map")
    }

    // MARK: - helpers

    private func makeWorker(reviewLog: ReviewLogStore, diffText: String) -> ReviewQueueWorker {
        let w = ReviewQueueWorker(diffFetcher: { _, _, _ in diffText })
        w.providerLookup = nil
        w.reviewLog = reviewLog
        return w
    }

    private func makePR(_ id: String = "PR_1", number: Int = 1) -> InboxPR {
        InboxPR(
            nodeId: id, owner: "o", repo: "r", number: number,
            title: "t \(number)", body: "", url: URL(string: "https://github.com/o/r/pull/\(number)")!,
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
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("waitUntil timed out")
    }
}
