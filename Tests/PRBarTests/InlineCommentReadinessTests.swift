import XCTest
@testable import PRBar

/// The gate that keeps a verdict from being posted without the findings
/// it came with. `DiffStoreHydrationTests` pins the window this closes.
final class InlineCommentReadinessTests: XCTestCase {

    /// The regression itself: annotations in hand, diff not yet hydrated.
    /// Both `.idle` (hydration not started) and `.loading` (in flight) are
    /// the same hazard — the mapping yields nothing in either.
    func testAnnotationsWithAnUnhydratedDiffBlockPosting() {
        for diff in [DiffStore.LoadStatus.idle, .loading] {
            XCTAssertEqual(
                InlineCommentReadiness.state(annotationCount: 3, diff: diff),
                .waitingForDiff,
                "\(diff) must not let a review post stripped of its annotations"
            )
        }
    }

    func testLoadedDiffIsReady() {
        XCTAssertEqual(
            InlineCommentReadiness.state(annotationCount: 3, diff: .loaded([])),
            .ready
        )
    }

    /// No annotations means nothing can be dropped, so the diff's state is
    /// irrelevant — an approve with no findings must not wait on a fetch.
    func testNoAnnotationsNeverBlocks() {
        for diff in [DiffStore.LoadStatus.idle, .loading, .loaded([]), .failed("nope")] {
            XCTAssertEqual(
                InlineCommentReadiness.state(annotationCount: 0, diff: diff),
                .nothingToPost,
                "\(diff) with no annotations has nothing to lose"
            )
        }
    }

    /// A diff that cannot be read is terminal, not transient. Blocking
    /// there would make the PR unreviewable from PRBar forever, which is
    /// worse than a review the user can see carries no inline comments.
    func testFailedDiffDoesNotBlockPosting() {
        XCTAssertEqual(
            InlineCommentReadiness.state(annotationCount: 3, diff: .failed("gh exploded")),
            .diffUnavailable
        )
        XCTAssertNotEqual(
            InlineCommentReadiness.state(annotationCount: 3, diff: .failed("gh exploded")),
            .waitingForDiff
        )
    }
}
