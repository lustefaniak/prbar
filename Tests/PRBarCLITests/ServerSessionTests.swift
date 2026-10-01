import XCTest
@testable import PRBarCore

/// The app's view of the server, over the in-process transport.
@MainActor
final class ServerSessionTests: XCTestCase {
    private func makeServer(prs: [InboxPR]) -> (PRBarRuntime, APIServer) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prbar-session-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let runtime = RuntimeFixtures.make(dir, ownsAutomation: false, prs: prs)
        let server = APIServer(runtime: runtime, holder: "test", build: "dev")
        addTeardownBlock { @MainActor in server.stop() }
        return (runtime, server)
    }

    /// Waits for the main actor to drain the updates already in flight.
    private func until(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition())
    }

    func testSnapshotThenUpdates() async throws {
        let (runtime, server) = makeServer(prs: [RuntimeFixtures.requestedPR()])
        let session = ServerSession(client: server.connectInProcess())
        defer { session.stop() }
        try await session.start()
        XCTAssertEqual(session.inbox.prs.map(\.nodeId), ["PR_1"], "the snapshot arrives with the subscribe reply")
        XCTAssertNotNil(session.inbox.lastFetchedAt)

        runtime.poller._setPRsForScreenshot([RuntimeFixtures.requestedPR(), RuntimeFixtures.requestedPR(nodeId: "PR_2", number: 2)])
        try await until { session.inbox.prs.count == 2 }
    }

    func testCommandsReachTheRuntime() async throws {
        let (runtime, server) = makeServer(prs: [RuntimeFixtures.requestedPR()])
        let session = ServerSession(client: server.connectInProcess())
        defer { session.stop() }
        try await session.start()

        runtime.poller._setPRsForScreenshot([])
        try await until { session.inbox.prs.isEmpty }
        session.inbox.pollNow()
        try await until { session.inbox.prs.map(\.nodeId) == ["PR_1"] }
    }

    /// Review state arrives per PR: a changed review is sent, an untouched
    /// one isn't, and one the server dropped is removed.
    func testReviewStateFollowsTheServer() async throws {
        let (runtime, server) = makeServer(prs: [RuntimeFixtures.requestedPR(), RuntimeFixtures.requestedPR(nodeId: "PR_2", number: 2)])
        let session = ServerSession(client: server.connectInProcess())
        defer { session.stop() }
        try await session.start()
        XCTAssertTrue(session.reviews.reviews.isEmpty)

        session.reviews.enqueue(session.inbox.prs[0], force: true, providerOverride: .codex)
        try await until { session.reviews.reviews["PR_1"]?.status.isInFlight == true }
        XCTAssertEqual(runtime.queue.reviews["PR_1"]?.providerId, .codex)
        XCTAssertEqual(session.reviews.reviews["PR_1"]?.providerId, .codex)

        runtime.queue._setReviewsForScreenshot([:])
        try await until { session.reviews.reviews.isEmpty }
    }

    func testUserOnlyControlsAreRefusedToAgents() {
        let agent = HelloParams(client: "mcp:x", protocolVersion: 1, agent: true)
        for method in [APIMethod.autoReviewUndo, .autoReviewPostNow, .autoReviewDismissFlagged, .setCostCap, .checkoutPrune] {
            XCTAssertEqual(APIServer.denial(of: method, by: agent, under: AgentPolicy())?.code, RPCError.notPermitted, method.rawValue)
        }
    }

    /// A write runs against the PR as the client saw it: a review must be
    /// posted on the commit the user reviewed, even if the server's copy of
    /// the PR has moved on since.
    func testWritesUseTheClientsSnapshot() async throws {
        let (runtime, server) = makeServer(prs: [RuntimeFixtures.requestedPR()])
        let posted = PostedHeads()
        runtime.actionQueue.reviewExecutor = { pr, _, _, _ in await posted.record(pr.headSha) }
        let session = ServerSession(client: server.connectInProcess())
        defer { session.stop() }
        try await session.start()

        let seen = RuntimeFixtures.requestedPR(headSha: "reviewed-sha")
        session.actions.enqueue(seen, kind: .review(kind: .approve, body: "", comments: []))
        try await until { session.actions.recentSuccess["PR_1"] != nil }
        let heads = await posted.heads
        XCTAssertEqual(heads, ["reviewed-sha"])
        XCTAssertFalse(session.actions.isBusy("PR_1"))
    }

    func testAgentWritesNeedTheirCapability() {
        var policy = AgentPolicy()
        XCTAssertNotNil(APIServer.denial(of: .review(kind: .approve, body: "", comments: []), under: policy), "post is `ask` by default")
        XCTAssertNotNil(APIServer.denial(of: .merge(method: .squash), under: policy))
        policy.post = .allow
        XCTAssertNil(APIServer.denial(of: .review(kind: .comment, body: "x", comments: []), under: policy))
        XCTAssertNotNil(APIServer.denial(of: .enableAutoMerge(method: .squash), under: policy), "merge stays off")
        policy.merge = .allow
        policy.post = .off
        XCTAssertNil(APIServer.denial(of: .merge(method: .rebase), under: policy))
        XCTAssertNil(APIServer.denial(of: .enqueueAction, by: HelloParams(client: "a", protocolVersion: 1, agent: true), under: policy),
                     "enqueue is decided per action, not refused for the method")
    }
}

private actor PostedHeads {
    var heads: [String] = []
    func record(_ sha: String) { heads.append(sha) }
}
