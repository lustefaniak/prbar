import XCTest
@testable import PRBar

final class RecommendedReviewTests: XCTestCase {
    private let diff = """
    diff --git a/a.go b/a.go
    --- a/a.go
    +++ b/a.go
    @@ -1,2 +1,3 @@
     package a
    +var x = 1
     func f() {}

    """

    private let onDiff = DiffAnnotation(path: "a.go", lineStart: 2, lineEnd: 2, severity: .warning, title: "Unchecked", body: "x is never read")
    private let offDiff = DiffAnnotation(path: "a.go", lineStart: 40, lineEnd: 40, severity: .info, title: "Far", body: "not in the diff")

    func testApproveWithNotesIsAnApprovalCarryingTheSummaryAndLineComments() throws {
        let plan = RecommendedReview.plan(state: state(.comment, [onDiff, offDiff]), headSha: "abc", body: nil, diffText: diff)
        guard case .post(.review(let kind, let body, let comments)) = plan else { return XCTFail("\(plan)") }
        XCTAssertEqual(kind, .approve)
        XCTAssertEqual(body, "summary")
        // Only the finding on a line of the diff can be a line comment.
        XCTAssertEqual(comments.map(\.line), [2])
        XCTAssertEqual(comments.first?.path, "a.go")
    }

    func testTheUsersBodyReplacesTheSummary() {
        let plan = RecommendedReview.plan(state: state(.approve), headSha: "abc", body: "  LGTM  ", diffText: "")
        XCTAssertEqual(plan, .post(.review(kind: .approve, body: "LGTM", comments: [])))
    }

    func testRequestChangesNeedsABody() {
        XCTAssertEqual(
            RecommendedReview.plan(state: state(.requestChanges), headSha: "abc", body: nil, diffText: ""),
            .post(.review(kind: .requestChanges, body: "summary", comments: [])))
        guard case .refuse = RecommendedReview.plan(state: state(.requestChanges), headSha: "abc", body: " ", diffText: "") else {
            return XCTFail("posted a request for changes without a body")
        }
    }

    func testRefusesWhenThereIsNothingCurrentToPost() {
        let refusals: [(ReviewState?, String)] = [
            (nil, "abc"),
            (state(.abstain), "abc"),
            (state(.approve), "newer"),
            (ReviewState(prNodeId: "PR_1", headSha: "abc", triggeredAt: Date(), status: .running, costUsd: 0), "abc"),
        ]
        for (state, head) in refusals {
            let plan = RecommendedReview.plan(state: state, headSha: head, body: nil, diffText: diff)
            guard case .refuse = plan else { return XCTFail("posted \(plan) for \(String(describing: state?.status)) at \(head)") }
        }
    }

    private func state(_ verdict: ReviewVerdict, _ annotations: [DiffAnnotation] = []) -> ReviewState {
        let review = AggregatedReview(
            verdict: verdict, confidence: 0.6, summaryMarkdown: "summary\n", annotations: annotations,
            costUsd: 0.01, toolCallCount: 0, toolNamesUsed: [], perSubreview: [], isSubscriptionAuth: false)
        return ReviewState(prNodeId: "PR_1", headSha: "abc", triggeredAt: Date(), status: .completed(review), costUsd: 0)
    }
}
