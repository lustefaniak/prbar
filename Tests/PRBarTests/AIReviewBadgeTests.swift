import XCTest
@testable import PRBar

final class AIReviewBadgeTests: XCTestCase {

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

    func testQueuedMapsToQueued() {
        let badge = AIReviewBadge(status: .queued, reviewedSha: nil, headSha: "abc", role: .reviewRequested)
        XCTAssertEqual(badge, .queued)
    }

    func testRunningMapsToRunning() {
        let badge = AIReviewBadge(status: .running, reviewedSha: nil, headSha: "abc", role: .reviewRequested)
        XCTAssertEqual(badge, .running)
    }

    func testFailedMapsToFailed() {
        let badge = AIReviewBadge(status: .failed("boom"), reviewedSha: "abc", headSha: "abc", role: .reviewRequested)
        XCTAssertEqual(badge, .failed)
    }

    func testCompletedAtCurrentHeadIsDone() {
        let badge = AIReviewBadge(status: .completed(makeAgg()), reviewedSha: "abc", headSha: "abc", role: .reviewRequested)
        XCTAssertEqual(badge, .done)
    }

    func testCompletedAtOlderHeadIsStale() {
        let badge = AIReviewBadge(status: .completed(makeAgg()), reviewedSha: "old", headSha: "new", role: .reviewRequested)
        XCTAssertEqual(badge, .doneStale)
    }

    func testNoStatusOnReviewRequestedRowIsNotYet() {
        XCTAssertEqual(AIReviewBadge(status: nil, reviewedSha: nil, headSha: "abc", role: .reviewRequested), .notYet)
        XCTAssertEqual(AIReviewBadge(status: nil, reviewedSha: nil, headSha: "abc", role: .both), .notYet)
    }

    func testNoStatusOnAuthoredOrOtherRowIsNil() {
        XCTAssertNil(AIReviewBadge(status: nil, reviewedSha: nil, headSha: "abc", role: .authored))
        XCTAssertNil(AIReviewBadge(status: nil, reviewedSha: nil, headSha: "abc", role: .other))
    }

    func testSkippedMapsToSkippedCarryingReason() {
        for reason in ReviewState.SkipReason.allCases {
            let badge = AIReviewBadge(status: .skipped(reason), reviewedSha: nil, headSha: "abc", role: .reviewRequested)
            XCTAssertEqual(badge, .skipped(reason))
        }
    }

    func testInFlightShowsRegardlessOfRole() {
        // A queued/running/done review is surfaced even on authored rows
        // (e.g. a manual re-run), since the entry itself proves intent.
        XCTAssertEqual(AIReviewBadge(status: .queued, reviewedSha: nil, headSha: "x", role: .authored), .queued)
        XCTAssertEqual(AIReviewBadge(status: .completed(makeAgg()), reviewedSha: "x", headSha: "x", role: .other), .done)
    }
}
