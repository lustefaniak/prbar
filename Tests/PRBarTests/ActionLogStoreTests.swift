import XCTest
@testable import PRBar

@MainActor
final class ActionLogStoreTests: XCTestCase {

    private func makePR() -> InboxPR {
        InboxPR(
            nodeId: "PR_TEST", owner: "acme", repo: "infra", number: 42,
            title: "Test PR", body: "", url: URL(string: "https://example.com")!,
            author: "alice", headRef: "feat", baseRef: "main",
            headSha: "deadbeef", isDraft: false,
            role: .reviewRequested,
            mergeable: "MERGEABLE", mergeStateStatus: "CLEAN", reviewDecision: nil,
            checkRollupState: "SUCCESS",
            totalAdditions: 10, totalDeletions: 2, changedFiles: 1,
            hasAutoMerge: false, autoMergeEnabledBy: nil, allCheckSummaries: [],
            allowedMergeMethods: [.squash], autoMergeAllowed: false,
            deleteBranchOnMerge: false
        )
    }

    func testRecordPersistsAndFetchOrdersByTimestamp() {
        let store = ActionLogStore(container: PRBarModelContainer.inMemory())
        let pr = makePR()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let t1 = t0.addingTimeInterval(60)
        store.record(kind: .approve, outcome: .success, pr: pr, detail: "approve", timestamp: t0)
        store.record(kind: .merge,   outcome: .success, pr: pr, detail: "squash",  timestamp: t1)

        let all = store.fetchAll()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].kind, .merge)
        XCTAssertEqual(all[1].kind, .approve)
        XCTAssertEqual(all[0].owner, "acme")
        XCTAssertEqual(all[0].repo, "infra")
        XCTAssertEqual(all[0].prNumber, 42)
        XCTAssertEqual(all[0].headSha, "deadbeef")
    }

    func testFailureOutcomeCarriesErrorMessage() {
        let store = ActionLogStore(container: PRBarModelContainer.inMemory())
        store.record(
            kind: .merge, outcome: .failure, pr: makePR(),
            errorMessage: "merge blocked: not approved", detail: "squash"
        )
        let all = store.fetchAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].outcome, .failure)
        XCTAssertEqual(all[0].errorMessage, "merge blocked: not approved")
    }

    func testClearAllRemovesEntries() {
        let store = ActionLogStore(container: PRBarModelContainer.inMemory())
        store.record(kind: .approve, outcome: .success, pr: makePR())
        XCTAssertEqual(store.fetchAll().count, 1)
        store.clearAll()
        XCTAssertEqual(store.fetchAll().count, 0)
    }
}
