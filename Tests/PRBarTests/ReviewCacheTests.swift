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

    private func stateDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prbar-state-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testRoundTripPreservesEntries() {
        let cache = ReviewStateFile(stateDirectory: stateDirectory())
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
        let cache = ReviewStateFile(stateDirectory: stateDirectory())
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

    func testEmptyLoadWithNoFile() {
        XCTAssertEqual(ReviewStateFile(stateDirectory: stateDirectory()).load().count, 0)
    }

    /// The fallback stands in for the pre-file store until the first save,
    /// so a completed review survives the storage move instead of being
    /// re-run and re-billed; after that the file wins.
    func testFallbackUntilTheFirstSave() {
        let legacy = ReviewState(prNodeId: "OLD", headSha: "1", triggeredAt: Date(),
                                 status: .completed(makeAgg()), costUsd: 0.05)
        let cache = ReviewStateFile(stateDirectory: stateDirectory(), fallback: { ["OLD": legacy] })
        XCTAssertEqual(cache.load().keys.sorted(), ["OLD"])

        cache.save([:])
        XCTAssertTrue(cache.load().isEmpty)
    }
}
