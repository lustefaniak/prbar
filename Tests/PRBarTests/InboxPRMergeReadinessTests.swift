import XCTest
@testable import PRBar

final class InboxPRMergeReadinessTests: XCTestCase {

    func testReadyAuthoredPRHasNoBlockReason() {
        let pr = makePR(role: .authored, mergeStateStatus: "CLEAN")
        XCTAssertTrue(pr.isReadyToMerge)
        XCTAssertNil(pr.mergeBlockReason)
    }

    func testDraftReportsDraftReason() {
        let pr = makePR(role: .authored, isDraft: true, mergeStateStatus: "CLEAN")
        XCTAssertFalse(pr.isReadyToMerge)
        XCTAssertEqual(pr.mergeBlockReason, "Draft — mark ready for review to merge")
    }

    func testNoAllowedMethodsReportsRepoReason() {
        let pr = makePR(role: .authored, mergeStateStatus: "CLEAN", allowedMergeMethods: [])
        XCTAssertEqual(pr.mergeBlockReason, "No merge method enabled for this repo")
    }

    func testChangesRequestedTakesPrecedence() {
        let pr = makePR(
            role: .authored, mergeStateStatus: "BLOCKED",
            reviewDecision: "CHANGES_REQUESTED"
        )
        XCTAssertEqual(pr.mergeBlockReason, "Changes requested")
    }

    func testReviewRequiredReason() {
        let pr = makePR(
            role: .authored, mergeStateStatus: "BLOCKED",
            reviewDecision: "REVIEW_REQUIRED"
        )
        XCTAssertEqual(pr.mergeBlockReason, "Review required")
    }

    func testConflictReason() {
        let pr = makePR(
            role: .authored, mergeable: "CONFLICTING", mergeStateStatus: "DIRTY"
        )
        XCTAssertEqual(pr.mergeBlockReason, "Merge conflicts — rebase needed")
    }

    func testFailingChecksReason() {
        let pr = makePR(
            role: .authored, mergeStateStatus: "BLOCKED",
            checkRollupState: "FAILURE"
        )
        XCTAssertEqual(pr.mergeBlockReason, "Checks failing")
    }

    func testPendingChecksReason() {
        let pr = makePR(
            role: .authored, mergeStateStatus: "BLOCKED",
            checkRollupState: "PENDING"
        )
        XCTAssertEqual(pr.mergeBlockReason, "Checks pending")
    }

    func testBlockedFallsBackToBranchProtection() {
        let pr = makePR(
            role: .authored, mergeStateStatus: "BLOCKED",
            checkRollupState: "SUCCESS"
        )
        XCTAssertEqual(pr.mergeBlockReason, "Blocked by branch protection")
    }

    // MARK: - helpers

    private func makePR(
        role: PRRole,
        isDraft: Bool = false,
        mergeable: String = "MERGEABLE",
        mergeStateStatus: String,
        reviewDecision: String? = nil,
        checkRollupState: String = "SUCCESS",
        allowedMergeMethods: Set<MergeMethod> = [.squash, .rebase]
    ) -> InboxPR {
        InboxPR(
            nodeId: "PR_x",
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
            mergeable: mergeable,
            mergeStateStatus: mergeStateStatus,
            reviewDecision: reviewDecision,
            checkRollupState: checkRollupState,
            totalAdditions: 1,
            totalDeletions: 0,
            changedFiles: 1,
            hasAutoMerge: false,
            autoMergeEnabledBy: nil,
            allCheckSummaries: [],
            allowedMergeMethods: allowedMergeMethods,
            autoMergeAllowed: true,
            deleteBranchOnMerge: true
        )
    }
}
