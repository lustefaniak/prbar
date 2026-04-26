import XCTest
@testable import PRBar

final class SnapshotCacheTests: XCTestCase {

    func testLoadReturnsEmptyOnFreshContainer() async {
        let cache = SnapshotCache(container: PRBarModelContainer.inMemory())
        let prs = await cache.load()
        XCTAssertTrue(prs.isEmpty)
    }

    func testRoundtripPreservesPRs() async {
        let cache = SnapshotCache(container: PRBarModelContainer.inMemory())
        let pr = makePR(nodeId: "P1", title: "Fix bug")
        await cache.save([pr])

        let loaded = await cache.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.nodeId, "P1")
        XCTAssertEqual(loaded.first?.title, "Fix bug")
    }

    func testSaveOverwritesExistingPR() async {
        let cache = SnapshotCache(container: PRBarModelContainer.inMemory())
        let v1 = makePR(nodeId: "P1", title: "v1")
        let v2 = makePR(nodeId: "P1", title: "v2")
        await cache.save([v1])
        await cache.save([v2])

        let loaded = await cache.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.title, "v2")
    }

    func testSaveDropsRowsForPRsThatLeftTheInbox() async {
        let cache = SnapshotCache(container: PRBarModelContainer.inMemory())
        let a = makePR(nodeId: "A", title: "a")
        let b = makePR(nodeId: "B", title: "b")
        await cache.save([a, b])
        await cache.save([a])
        let loaded = await cache.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.nodeId, "A")
    }

    func testClearRemovesAllRows() async {
        let cache = SnapshotCache(container: PRBarModelContainer.inMemory())
        await cache.save([makePR(nodeId: "P1", title: "x")])
        await cache.clear()

        let loaded = await cache.load()
        XCTAssertTrue(loaded.isEmpty)
    }

    @MainActor
    func testPRPollerLoadCachedSeedsPRs() async throws {
        let cache = SnapshotCache(container: PRBarModelContainer.inMemory())
        let pr = makePR(nodeId: "P1", title: "from disk")
        await cache.save([pr])

        let poller = PRPoller(fetcher: { [] }, cache: cache)
        XCTAssertTrue(poller.prs.isEmpty)

        await poller.loadCached()
        XCTAssertEqual(poller.prs.first?.nodeId, "P1")
        XCTAssertEqual(poller.prs.first?.title, "from disk")
    }

    @MainActor
    func testPRPollerLoadCachedNoOpWhenAlreadyPopulated() async throws {
        let cache = SnapshotCache(container: PRBarModelContainer.inMemory())
        await cache.save([makePR(nodeId: "P1", title: "from disk")])

        let fresh = makePR(nodeId: "P2", title: "fresh")
        let poller = PRPoller(
            fetcher: { [fresh] },
            cache: cache
        )
        poller.pollNow()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(poller.prs.first?.title, "fresh")

        await poller.loadCached()
        XCTAssertEqual(poller.prs.first?.title, "fresh")
    }

    // MARK: helpers

    private func makePR(nodeId: String, title: String) -> InboxPR {
        InboxPR(
            nodeId: nodeId,
            owner: "o",
            repo: "r",
            number: 1,
            title: title,
            body: "",
            url: URL(string: "https://github.com/o/r/pull/1")!,
            author: "a",
            headRef: "h",
            baseRef: "main",
            headSha: "abc123",
            isDraft: false,
            role: .authored,
            mergeable: "MERGEABLE",
            mergeStateStatus: "CLEAN",
            reviewDecision: "APPROVED",
            checkRollupState: "SUCCESS",
            totalAdditions: 1,
            totalDeletions: 0,
            changedFiles: 1,
            hasAutoMerge: false,
            autoMergeEnabledBy: nil,
            allCheckSummaries: [],
            allowedMergeMethods: [.squash, .rebase],
            autoMergeAllowed: true,
            deleteBranchOnMerge: true
        )
    }
}
