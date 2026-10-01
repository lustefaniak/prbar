import XCTest
@testable import PRBarCore

/// `prbar-review <pr>` through a real server on a real socket: the same
/// NDJSON a standalone run prints, with the review run by the server.
@MainActor
final class ClientReviewTests: XCTestCase {
    private var dir: URL!
    private var socketURL: URL!

    override func setUp() async throws {
        dir = URL(fileURLWithPath: "/tmp/prbar-cr-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        socketURL = dir.appendingPathComponent("server.sock")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A server whose inbox is empty: the PR is found by fetching it, as a
    /// one-off review of any PR is.
    private func startServer(pr: InboxPR = RuntimeFixtures.requestedPR(), config: String? = nil) throws -> (PRBarRuntime, APIServer) {
        if let config {
            try config.write(to: dir.appendingPathComponent("prbar.yaml"), atomically: true, encoding: .utf8)
        }
        let runtime = RuntimeFixtures.make(dir, ownsAutomation: false, prs: [], github: [pr])
        runtime.queue.providerLookup = { _ in StubReviewProvider() }
        runtime.queue.undoWindow = 0
        let server = APIServer(runtime: runtime, holder: "test", build: "dev")
        try server.start(socketURL: socketURL)
        addTeardownBlock { @MainActor in server.stop() }
        return (runtime, server)
    }

    private final class Captured {
        var events: [BrahmandaEvent] = []
        var reviews: [ReviewOutput] = []
        var logs: [String] = []
    }

    private func review(_ args: [String], configFile: URL? = nil) async throws -> (Int32, Captured) {
        let captured = Captured()
        let socket = socketURL!
        var run = ClientReview(
            invocation: try XCTUnwrap(Invocation(args: args)),
            configFile: configFile,
            connect: { try await ServerConnection.connect(socketURL: socket, client: "prbar-review") })
        run.emit = { captured.events.append($0) }
        run.writeReview = { output, _ in captured.reviews.append(output) }
        run.log = { captured.logs.append($0) }
        run.pollInterval = .milliseconds(20)
        return (await run.run(), captured)
    }

    func testReviewsAPROutsideTheInboxAndReportsItAsNDJSON() async throws {
        let (runtime, _) = try startServer()
        let (code, out) = try await review(["--review-json", "-", "o/r#1"])
        XCTAssertEqual(code, 0, out.logs.joined())
        XCTAssertEqual(out.events.map(\.outcome.rawValue), ["started", "succeeded"])
        XCTAssertEqual(out.events.first?.note, "abc123 t")
        XCTAssertEqual(out.events.last?.note, "approve (confidence 99%); 0 findings; nothing posted (no gate fired)")
        XCTAssertEqual(out.reviews.map(\.task_id), ["o/r#1"])
        XCTAssertEqual(out.reviews.first?.posted, false)
        // The server ran it, so the app's history keeps it.
        XCTAssertEqual(runtime.reviewLog.entries.map(\.prNumber), [1])
    }

    func testTheSameCommitTwiceIsAnsweredFromTheFirstReview() async throws {
        try startServer()
        _ = try await review(["o/r#1"])
        let (_, again) = try await review(["o/r#1"])
        XCTAssertTrue(again.events.last?.note?.contains("reviewed earlier at this commit") ?? false, "\(String(describing: again.events.last?.note))")
        XCTAssertNil(again.events.last?.agent?.cost_usd, "a budget must not be billed twice")
    }

    func testANotRequestedPRIsLeftAloneUnlessForced() async throws {
        let mine = RuntimeFixtures.requestedPR(role: .authored)
        let (runtime, _) = try startServer(pr: mine)
        let (_, out) = try await review(["o/r#1"])
        XCTAssertEqual(out.events.map(\.outcome.rawValue), ["started", "succeeded"])
        XCTAssertEqual(out.events.last?.note, "not reviewed: no review request for the authenticated user (pass --force to review anyway)")
        XCTAssertNil(runtime.queue.reviews["PR_1"])

        let (_, forced) = try await review(["--force", "o/r#1"])
        XCTAssertTrue(forced.events.last?.note?.hasPrefix("approve") ?? false, "\(String(describing: forced.events.last?.note))")
    }

    /// The process waits for the post, not only the review, so the terminal
    /// event still means the work landed.
    func testWaitsForTheAutoPost() async throws {
        let (runtime, _) = try startServer(config: "defaults:\n  autoApprove:\n    enabled: true\n")
        runtime.repoConfigs.reloadIfChanged()
        let posted = PostedHeads()
        runtime.actionQueue.reviewExecutor = { pr, _, _, _ in
            try await Task.sleep(for: .milliseconds(200))
            await posted.record(pr.headSha)
        }
        let (_, out) = try await review(["--review-json", "-", "o/r#1"])
        let heads = await posted.heads
        XCTAssertEqual(heads, ["abc123"])
        XCTAssertTrue(out.events.last?.note?.contains("posted auto_approve") ?? false, "\(String(describing: out.events.last?.note))")
        XCTAssertEqual(out.reviews.first?.posted, true)
    }

    func testRefusesAServerReadingAnotherConfig() async throws {
        try startServer()
        let other = dir.appendingPathComponent("other.yaml")
        let (code, out) = try await review(["o/r#1"], configFile: other)
        XCTAssertEqual(code, 2)
        XCTAssertEqual(out.events.count, 0)
        XCTAssertTrue(out.logs.joined().contains("--standalone"), out.logs.joined())

        let (same, _) = try await review(["o/r#1"], configFile: dir.appendingPathComponent("prbar.yaml"))
        XCTAssertEqual(same, 0)
    }

    func testAPRThatCanNotBeFetchedIsAFailedEvent() async throws {
        try startServer()
        let (code, out) = try await review(["o/r#404"])
        XCTAssertEqual(code, 1)
        XCTAssertEqual(out.events.map(\.outcome.rawValue), ["failed"])
    }

    // MARK: - On-demand servers

    func testIdleOnlyWithoutClientsOrWork() async throws {
        let (runtime, server) = try startServer()
        XCTAssertTrue(server.isIdle)
        let client = try await ServerConnection.connect(socketURL: socketURL, client: "x").client
        try await waitFor { !server.isIdle }
        client.close()
        try await waitFor { server.isIdle }
        runtime.queue.providerLookup = { _ in NeverProvider() }
        runtime.queue.enqueue(RuntimeFixtures.requestedPR(), force: true)
        XCTAssertFalse(server.isIdle, "a review in flight keeps it up")
    }

    func testTheAppAdoptsAnOnDemandServer() async throws {
        let (runtime, server) = try startServer()
        server.idleExitSeconds = 300
        var adoptedBy: Int32?
        server.onAdopt = { adoptedBy = $0 }
        let connected = try await ServerLauncher.connect(
            socketURL: socketURL, client: "PRBar.app",
            executable: .init(path: "/nonexistent", log: dir.appendingPathComponent("log")),
            expectedBuild: "another build", adoptAs: 4242)
        defer { connected.client.close() }
        XCTAssertEqual(adoptedBy, 4242)
        XCTAssertEqual(connected.hello.exitsWith, 4242)
        XCTAssertTrue(runtime.ownsAutomation)
        XCTAssertNil(server.idleExitSeconds)
        let hello = try await ServerConnection.connect(socketURL: socketURL, client: "y")
        defer { hello.client.close() }
        XCTAssertEqual(hello.hello.exitsWith, 4242)
    }

    func testServeTakesIdleExit() {
        XCTAssertEqual(ServeCommand.Options(args: ["--idle-exit", "300"])?.idleExitSeconds, 300)
        XCTAssertNil(ServeCommand.Options(args: ["--idle-exit", "0"]))
        XCTAssertTrue(Invocation(args: ["--standalone", "o/r#1"])?.standalone ?? false)
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition())
    }
}
