import XCTest
@testable import PRBarCore

/// The app's view of the server, over the in-process transport.
@MainActor
final class ServerSessionTests: XCTestCase {
    private func makeServer(
        prs: [InboxPR],
        prDiff: @escaping @Sendable (String, String, Int) async throws -> String = { _, _, _ in RuntimeFixtures.diff }
    ) -> (PRBarRuntime, APIServer) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prbar-session-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let runtime = RuntimeFixtures.make(dir, ownsAutomation: false, prs: prs, prDiff: prDiff)
        let server = APIServer(runtime: runtime, holder: "test", build: "dev")
        addTeardownBlock { @MainActor in server.stop() }
        return (runtime, server)
    }

    /// Waits for the main actor to drain the updates already in flight.
    private func until(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let met = await condition()
        XCTAssertTrue(met)
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
        for method in [APIMethod.autoReviewUndo, .autoReviewPostNow, .autoReviewDismissFlagged, .setPreferences, .checkoutPrune] {
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

    /// "Reload diff" is invalidate then load, back to back, and must reach
    /// `gh` exactly once more. Order on the wire is pinned by
    /// `testCommandsAreSentInOrderBeforeReturning`, order in the server by
    /// `RequestOrderTests`.
    func testReloadingADiffFetchesItAgain() async throws {
        let fetches = PostedHeads()
        let (_, server) = makeServer(prs: [RuntimeFixtures.requestedPR()]) { _, _, _ in
            await fetches.record("fetch")
            return RuntimeFixtures.diff
        }
        let session = ServerSession(client: server.connectInProcess())
        defer { session.stop() }
        try await session.start()
        let pr = session.inbox.prs[0]

        session.diffs.ensureLoaded(for: pr)
        try await until { if case .loaded(let hunks) = session.diffs.status(for: pr) { return !hunks.isEmpty }; return false }

        let before = await fetches.heads.count
        XCTAssertEqual(before, 1)
        session.diffs.invalidate(for: pr)
        session.diffs.ensureLoaded(for: pr)
        try await until { await fetches.heads.count == 2 }
        try await until { if case .loaded = session.diffs.status(for: pr) { return true }; return false }
        try await Task.sleep(for: .milliseconds(100))
        let after = await fetches.heads.count
        XCTAssertEqual(after, 2, "one reload, one fetch: neither skipped (load before invalidate) nor doubled")
    }

    /// Commands leave in the order the UI issues them, before `send`
    /// returns. Sent from separate tasks instead, invalidate-then-load could
    /// reach the server reversed, and the load would find the old diff.
    func testCommandsAreSentInOrderBeforeReturning() throws {
        let transport = RecordingTransport()
        let session = ServerSession(client: APIClient(transport: transport))
        let pr = RuntimeFixtures.requestedPR()

        session.diffs.invalidate(for: pr)
        session.diffs.ensureLoaded(for: pr)
        session.inbox.pollNow()

        XCTAssertEqual(transport.methods, ["diff.invalidate", "diff.load", "poll"])
    }

    func testConfigEditsReachTheFileAndHandEditsComeBack() async throws {
        let (runtime, server) = makeServer(prs: [])
        let session = ServerSession(client: server.connectInProcess())
        defer { session.stop() }
        try await session.start()
        let model = session.config
        XCTAssertEqual(model.path, runtime.repoConfigs.fileURL.path)

        // A burst, as a text field produces: the model shows the last value
        // at once, and the server ends on it rather than an older echo.
        for usd in stride(from: 1.0, through: 9.0, by: 1.0) {
            model.defaults.maxCostUsdPerSubreview = usd
        }
        XCTAssertEqual(model.defaults.maxCostUsdPerSubreview, 9)
        try await until { runtime.repoConfigs.defaults.maxCostUsdPerSubreview == 9 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.defaults.maxCostUsdPerSubreview, 9)
        let text = try String(contentsOf: runtime.repoConfigs.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("maxCostUsdPerSubreview: 9"), text)

        // Rule ids are UI identity: they survive the round trip, so the
        // Settings selection does too.
        var rule = RepoConfig.default
        rule.repoGlobs = ["o/r"]
        model.upsert(rule)
        try await until { runtime.repoConfigs.userConfigs.first?.id == rule.id }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.userConfigs.map(\.id), [rule.id])

        try "repos:\n  - repoGlobs: [x/y]\n".write(to: runtime.repoConfigs.fileURL, atomically: true, encoding: .utf8)
        runtime.repoConfigs.reloadIfChanged()
        try await until { model.userConfigs.map(\.repoGlobs) == [["x/y"]] }

        try "repos: [broken".write(to: runtime.repoConfigs.fileURL, atomically: true, encoding: .utf8)
        runtime.repoConfigs.reloadIfChanged()
        try await until { model.loadIssue != nil }
        XCTAssertEqual(model.userConfigs.map(\.repoGlobs), [["x/y"]], "a broken file keeps the config in effect")
    }

    func testHistoryArrivesAsAppendsAndFullReviewsOnRequest() async throws {
        let (runtime, server) = makeServer(prs: [])
        let pr = RuntimeFixtures.requestedPR()
        let review = AggregatedReview(
            verdict: .approve, confidence: 0.9, summaryMarkdown: "fine", annotations: [],
            costUsd: 0.1, toolCallCount: 0, toolNamesUsed: [], perSubreview: [], isSubscriptionAuth: false)
        runtime.reviewLog.recordCompleted(pr: pr, headSha: pr.headSha, providerId: .claude, triggeredAt: Date(), review: review)

        let session = ServerSession(client: server.connectInProcess())
        defer { session.stop() }
        try await session.start()
        XCTAssertEqual(session.reviewLog.entries.count, 1, "the snapshot carries the log")
        let id = session.reviewLog.entries[0].id

        XCTAssertNil(session.reviewLog.review(for: id))
        XCTAssertTrue(session.reviewLog.isLoadingReview(id))
        try await until { session.reviewLog.review(for: id)?.summaryMarkdown == "fine" }
        XCTAssertFalse(session.reviewLog.isLoadingReview(id))

        let unknown = UUID()
        _ = session.reviewLog.review(for: unknown)
        try await until { !session.reviewLog.isLoadingReview(unknown) }
        XCTAssertNil(session.reviewLog.review(for: unknown))

        runtime.actionLog.record(kind: ActionLogKind.allCases[0], outcome: .success, pr: pr)
        try await until { session.actionLog.entries.count == 1 }

        session.reviewLog.clearAll()
        try await until { session.reviewLog.entries.isEmpty }
    }

    func testLogUpdates() {
        let a = "a", b = "b", c = "c"
        XCTAssertEqual(LogUpdate.between([b, c], [a, b, c]), LogUpdate(added: [a]))
        XCTAssertEqual(LogUpdate.between([a, b, c], [a, c]), LogUpdate(reset: [a, c]))
        XCTAssertEqual(LogUpdate.between([b, c], [a, c]), LogUpdate(reset: [a, c]), "same count, different rows")
        XCTAssertEqual(LogUpdate(added: [a]).applied(to: [b, c]), [a, b, c])
    }

    /// Notifications go to a front end that subscribed to show them, and to
    /// the host's own deliverer only while none has.
    func testNotificationsGoToTheSubscribedFrontEnd() async throws {
        let (_, server) = makeServer(prs: [])
        let fallback = RecordingDeliverer()
        let relay = RelayDeliverer(fallback: fallback)
        server.relayNotifications(from: relay)
        let event = NotificationEvent(
            kind: .ciFailed, prNodeId: "PR_1", prTitle: "t", prRepo: "o/r", prNumber: 1,
            prURL: URL(string: "https://github.com/o/r/pull/1")!)

        await relay.deliver([event])
        var fallbackCount = await fallback.batches.count
        XCTAssertEqual(fallbackCount, 1, "nobody subscribed yet")

        let shown = RecordingDeliverer()
        let session = ServerSession(client: server.connectInProcess())
        try await session.start(deliverer: shown)
        await relay.deliver([event])
        try await until { await shown.batches.count == 1 }
        fallbackCount = await fallback.batches.count
        XCTAssertEqual(fallbackCount, 1)

        session.stop()
        try await until { server.forward([event]) == false }
        await relay.deliver([event])
        fallbackCount = await fallback.batches.count
        XCTAssertEqual(fallbackCount, 2, "back to the fallback once the front end is gone")
    }

    /// A write the server never got is a visible failure with Retry, not a
    /// silent drop: the UI clears the review draft and moves on only once
    /// the server has accepted it.
    /// A hand edit to prbar.yaml landing while a Settings edit is on its
    /// way: the whole-config write must not erase it, and Settings must end
    /// up showing the file rather than its own stale copy.
    func testHandEditDuringASettingsWriteWins() async throws {
        let (runtime, server) = makeServer(prs: [])
        let session = ServerSession(client: server.connectInProcess())
        defer { session.stop() }
        try await session.start()
        let model = session.config
        let file = runtime.repoConfigs.fileURL
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)

        var edited = false
        server._beforeHandling = { method in
            guard method == .setConfig, !edited else { return }
            edited = true
            try? "defaults:\n  maxCostUsdPerSubreview: 42\n".write(to: file, atomically: true, encoding: .utf8)
            runtime.repoConfigs.reloadIfChanged()
        }
        model.defaults.reviewTimeoutSeconds = 123
        try await until { model.defaults.maxCostUsdPerSubreview == 42 }
        XCTAssertEqual(runtime.repoConfigs.defaults.maxCostUsdPerSubreview, 42, "the hand edit survived")
        XCTAssertNotEqual(runtime.repoConfigs.defaults.reviewTimeoutSeconds, 123, "the stale write was refused")
        XCTAssertTrue(model.loadIssue?.contains("changed while you were editing") ?? false, model.loadIssue ?? "")

        // The next edit is based on the file's state and saves.
        model.defaults.reviewTimeoutSeconds = 321
        try await until { runtime.repoConfigs.defaults.reviewTimeoutSeconds == 321 }
        XCTAssertEqual(runtime.repoConfigs.defaults.maxCostUsdPerSubreview, 42)
        try await until { model.loadIssue == nil }
    }

    func testWritesThatNeverReachTheServerAreShownAsFailed() async throws {
        let (runtime, server) = makeServer(prs: [RuntimeFixtures.requestedPR()])
        let posted = PostedHeads()
        runtime.actionQueue.reviewExecutor = { pr, _, _, _ in await posted.record(pr.headSha) }
        let client = server.connectInProcess()
        let session = ServerSession(client: client)
        try await session.start()
        let pr = RuntimeFixtures.requestedPR()

        client.close()
        var accepted = false
        session.actions.enqueue(pr, kind: .review(kind: .approve, body: "lgtm", comments: [])) { accepted = true }
        try await until { session.actions.state(for: "PR_1")?.failureMessage != nil }
        XCTAssertFalse(accepted)
        XCTAssertTrue(session.actions.state(for: "PR_1")?.failureMessage?.contains("isn't reachable") ?? false)
        let none = await posted.heads
        XCTAssertEqual(none, [])

        // Back on a live connection, Retry sends the same write.
        let live = ServerSession(client: server.connectInProcess())
        defer { live.stop() }
        try await live.start()
        live.actions.enqueue(pr, kind: .review(kind: .approve, body: "lgtm", comments: [])) { accepted = true }
        try await until { accepted }
        try await until { await posted.heads.count == 1 }
        XCTAssertNil(live.actions.unsent["PR_1"])

        session.actions.dismissFailure("PR_1")
        XCTAssertNil(session.actions.state(for: "PR_1"), "dismiss clears a write that was never sent")
    }
}

private actor RecordingDeliverer: NotificationDeliverer {
    var batches: [[NotificationEvent]] = []
    func requestAuthorization() async {}
    func deliver(_ events: [NotificationEvent]) async { batches.append(events) }
}

private final class RecordingTransport: APIClientTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [Data] = []

    var methods: [String] {
        lock.withLock { lines }.compactMap { try? RPCLine.decode(RPCHeader.self, from: $0).method }
    }

    func send(_ line: Data) -> Bool {
        lock.withLock { lines.append(line) }
        return true
    }

    func start(onLine: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {}
    func close() {}

}

private actor PostedHeads {
    var heads: [String] = []
    func record(_ sha: String) { heads.append(sha) }
}
