import XCTest
@testable import PRBar

final class ReviewAdvanceTests: XCTestCase {
    /// The double-approve guard: `poller.prs` still shows a just-approved
    /// PR as review-requested until the next poll, so only the handled set
    /// keeps sequential focus from walking back onto it.
    func testHandledPRIsNotOfferedAgainEvenWhileStillReviewRequested() {
        let prs = [makePR("a"), makePR("b")]

        let first = ReviewAdvance.next(in: prs, handled: [], triageStatus: { _ in nil })
        XCTAssertEqual(first?.nodeId, "a")

        let second = ReviewAdvance.next(in: prs, handled: ["a"], triageStatus: { _ in nil })
        XCTAssertEqual(second?.nodeId, "b")

        let third = ReviewAdvance.next(in: prs, handled: ["a", "b"], triageStatus: { _ in nil })
        XCTAssertNil(third, "nothing left once both are handled")
    }

    func testSkipsDraftsOthersDecisionsAndInFlightTriage() {
        let draft = makePR("draft", isDraft: true)
        let authored = makePR("mine", role: .authored)
        let decided = makePR("decided", reviewDecision: "APPROVED")
        let running = makePR("running")
        let ok = makePR("ok")

        let next = ReviewAdvance.next(
            in: [draft, authored, decided, running, ok],
            handled: [],
            triageStatus: { $0 == "running" ? .running : nil }
        )
        XCTAssertEqual(next?.nodeId, "ok")
    }

    private func makePR(
        _ nodeId: String,
        isDraft: Bool = false,
        role: PRRole = .reviewRequested,
        reviewDecision: String = "REVIEW_REQUIRED"
    ) -> InboxPR {
        InboxPR(
            nodeId: nodeId,
            owner: "o",
            repo: "r",
            number: 1,
            title: "t",
            body: "",
            url: URL(string: "https://github.com/o/r/pull/1")!,
            author: "alice",
            headRef: "h",
            baseRef: "main",
            headSha: "abc",
            isDraft: isDraft,
            role: role,
            mergeable: "MERGEABLE",
            mergeStateStatus: "BLOCKED",
            reviewDecision: reviewDecision,
            checkRollupState: "SUCCESS",
            totalAdditions: 1,
            totalDeletions: 0,
            changedFiles: 1,
            hasAutoMerge: false,
            autoMergeEnabledBy: nil,
            allCheckSummaries: [],
            allowedMergeMethods: [.squash],
            autoMergeAllowed: true,
            deleteBranchOnMerge: true
        )
    }
}
