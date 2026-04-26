import XCTest
@testable import PRBar

final class ReviewCacheTests: XCTestCase {

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

    func testRoundTripPreservesEntries() {
        let cache = ReviewCache(container: PRBarModelContainer.inMemory())
        let state = ReviewState(
            prNodeId: "PR_X", headSha: "abc",
            triggeredAt: Date(timeIntervalSince1970: 1_700_000_000),
            status: .completed(makeAgg()),
            costUsd: 0.05
        )
        cache.save(["PR_X": state])

        let loaded = cache.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded["PR_X"]?.headSha, "abc")
        if case .completed(let agg) = loaded["PR_X"]?.status {
            XCTAssertEqual(agg.verdict, .approve)
        } else {
            XCTFail("expected .completed status")
        }
    }

    func testSaveReplacesAndDeletesMissingKeys() {
        let cache = ReviewCache(container: PRBarModelContainer.inMemory())
        let s1 = ReviewState(prNodeId: "A", headSha: "1", triggeredAt: Date(), status: .queued, costUsd: 0)
        let s2 = ReviewState(prNodeId: "B", headSha: "2", triggeredAt: Date(), status: .queued, costUsd: 0)
        cache.save(["A": s1, "B": s2])
        XCTAssertEqual(cache.load().count, 2)

        // Drop B; only A should remain.
        cache.save(["A": s1])
        let after = cache.load()
        XCTAssertEqual(after.count, 1)
        XCTAssertNotNil(after["A"])
        XCTAssertNil(after["B"])
    }

    func testEmptyLoadOnFreshContainer() {
        let cache = ReviewCache(container: PRBarModelContainer.inMemory())
        XCTAssertEqual(cache.load().count, 0)
    }
}
