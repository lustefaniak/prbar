import XCTest
@testable import PRBar

final class EventDeriverTests: XCTestCase {
    func testNewReviewRequestEmitsEvent() {
        let pr = makePR(nodeId: "P1", role: .reviewRequested)
        let delta = PollDelta(added: [pr], removed: [], changed: [])

        let events = EventDeriver.events(from: delta, oldPRs: [])
        XCTAssertEqual(events.map(\.kind), [.newReviewRequest])
        XCTAssertEqual(events.first?.prNodeId, "P1")
    }

    func testAddedAuthoredAlreadyMergeableEmitsReadyToMerge() {
        let pr = makePR(
            nodeId: "P1",
            role: .authored,
            mergeStateStatus: "CLEAN",
            reviewDecision: "APPROVED"
        )
        let delta = PollDelta(added: [pr], removed: [], changed: [])

        let events = EventDeriver.events(from: delta, oldPRs: [])
        XCTAssertEqual(events.map(\.kind), [.readyToMerge])
    }

    func testTransitionToMergeableEmits() {
        let before = makePR(nodeId: "P1", role: .authored, mergeStateStatus: "BLOCKED", reviewDecision: "REVIEW_REQUIRED")
        let after  = makePR(nodeId: "P1", role: .authored, mergeStateStatus: "CLEAN",   reviewDecision: "APPROVED")
        let delta = PollDelta(added: [], removed: [], changed: [after])

        let events = EventDeriver.events(from: delta, oldPRs: [before])
        XCTAssertEqual(events.map(\.kind), [.readyToMerge])
    }

    func testNoEventWhenAlreadyMergeableInPreviousPoll() {
        // We shouldn't notify "ready to merge" again if it was already
        // ready last poll — only on the transition.
        let before = makePR(nodeId: "P1", role: .authored, mergeStateStatus: "CLEAN", reviewDecision: "APPROVED")
        let after  = makePR(nodeId: "P1", role: .authored, mergeStateStatus: "CLEAN", reviewDecision: "APPROVED",
                            title: "renamed")
        let delta = PollDelta(added: [], removed: [], changed: [after])

        let events = EventDeriver.events(from: delta, oldPRs: [before])
        XCTAssertTrue(events.isEmpty, "no transition; nothing to notify")
    }

    func testCITransitionToFailingEmits() {
        let before = makePR(nodeId: "P1", role: .authored, checkRollupState: "PENDING")
        let after  = makePR(nodeId: "P1", role: .authored, checkRollupState: "FAILURE")
        let delta = PollDelta(added: [], removed: [], changed: [after])

        let events = EventDeriver.events(from: delta, oldPRs: [before])
        XCTAssertEqual(events.map(\.kind), [.ciFailed])
    }

    func testDraftDoesNotCountAsReadyToMerge() {
        let pr = makePR(
            nodeId: "P1",
            role: .authored,
            isDraft: true,
            mergeStateStatus: "CLEAN",
            reviewDecision: "APPROVED"
        )
        let delta = PollDelta(added: [pr], removed: [], changed: [])
        let events = EventDeriver.events(from: delta, oldPRs: [])
        XCTAssertTrue(events.isEmpty, "draft PR should not be considered ready")
    }

    func testReviewRequestForReviewerOnlyDoesNotEmitMergeReady() {
        let pr = makePR(
            nodeId: "P1",
            role: .reviewRequested,
            mergeStateStatus: "CLEAN",
            reviewDecision: "APPROVED"
        )
        let delta = PollDelta(added: [pr], removed: [], changed: [])
        let events = EventDeriver.events(from: delta, oldPRs: [])
        XCTAssertEqual(events.map(\.kind), [.newReviewRequest],
            "I'm not the author — readyToMerge shouldn't fire")
    }

    // MARK: helpers

    private func makePR(
        nodeId: String,
        role: PRRole,
        isDraft: Bool = false,
        mergeStateStatus: String = "BLOCKED",
        reviewDecision: String? = nil,
        checkRollupState: String = "PENDING",
        title: String = "t"
    ) -> InboxPR {
        InboxPR(
            nodeId: nodeId,
            owner: "o",
            repo: "r",
            number: 1,
            title: title,
            body: "",
            url: URL(string: "https://github.com/o/r/pull/1")!,
            author: "alice",
            headRef: "h",
            baseRef: "main",
            isDraft: isDraft,
            role: role,
            mergeable: "MERGEABLE",
            mergeStateStatus: mergeStateStatus,
            reviewDecision: reviewDecision,
            checkRollupState: checkRollupState,
            totalAdditions: 1,
            totalDeletions: 0,
            changedFiles: 1,
            hasAutoMerge: false,
            autoMergeEnabledBy: nil,
            allCheckSummaries: []
        )
    }
}
