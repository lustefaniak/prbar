import XCTest
@testable import PRBarCore

/// `prbar-review mcp` speaking MCP on one side and the API on the other,
/// against a real server on a real socket.
@MainActor
final class MCPSessionTests: XCTestCase {
    private var dir: URL!
    private var socketURL: URL!

    override func setUp() async throws {
        dir = URL(fileURLWithPath: "/tmp/prbar-mcp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        socketURL = dir.appendingPathComponent("server.sock")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func startServer(prs: [InboxPR] = [RuntimeFixtures.requestedPR()]) throws -> PRBarRuntime {
        let runtime = RuntimeFixtures.make(dir, ownsAutomation: false, prs: prs)
        let server = APIServer(runtime: runtime, holder: "test", build: "dev")
        try server.start(socketURL: socketURL)
        addTeardownBlock { @MainActor in server.stop() }
        return runtime
    }

    private func send(_ session: MCPSession, _ json: String) async throws -> [String: Any] {
        let raw = await session.handle(Data(json.utf8))
        let reply = try XCTUnwrap(raw, "no reply to \(json)")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
    }

    /// The text of a tools/call result, and whether it is an error.
    private func call(_ session: MCPSession, _ tool: String, _ arguments: String = "{}") async throws -> (text: String, isError: Bool) {
        let reply = try await send(session, #"{"jsonrpc":"2.0","id":"t1","method":"tools/call","params":{"name":"\#(tool)","arguments":\#(arguments)}}"#)
        XCTAssertEqual(reply["id"] as? String, "t1")
        let result = try XCTUnwrap(reply["result"] as? [String: Any], "\(reply)")
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return (content.compactMap { $0["text"] as? String }.joined(), result["isError"] as? Bool ?? false)
    }

    func testInitializeNegotiatesTheProtocolVersion() async throws {
        let session = MCPSession(socketURL: socketURL)
        let known = try await send(session, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","clientInfo":{"name":"claude-code"}}}"#)
        let result = try XCTUnwrap(known["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-03-26")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])

        let unknown = try await send(session, #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        XCTAssertEqual((unknown["result"] as? [String: Any])?["protocolVersion"] as? String, MCPSession.protocolVersions[0])

        let notification = await session.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        XCTAssertNil(notification)
    }

    func testToolsList() async throws {
        let reply = try await send(MCPSession(socketURL: socketURL), #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)
        let tools = try XCTUnwrap((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["status", "list_inbox", "get_review", "run_review", "get_history", "watch"])
        for tool in tools {
            XCTAssertEqual((tool["inputSchema"] as? [String: Any])?["type"] as? String, "object", "\(tool)")
        }
    }

    func testWithoutAServerToolsSayWhatToDo() async throws {
        let (text, isError) = try await call(MCPSession(socketURL: socketURL), "status")
        XCTAssertTrue(isError)
        XCTAssertTrue(text.contains("Start PRBar.app or `prbar-review serve`"), text)
    }

    func testReadAndReviewTools() async throws {
        let runtime = try startServer()
        let session = MCPSession(socketURL: socketURL)

        let status = try await call(session, "status")
        XCTAssertFalse(status.isError, status.text)
        XCTAssertTrue(status.text.contains("1 PRs, 1 awaiting your review"), status.text)

        let inbox = try await call(session, "list_inbox", #"{"filter":"review_requested"}"#)
        XCTAssertTrue(inbox.text.contains("o/r#1 [review requested] t"), inbox.text)
        XCTAssertTrue(inbox.text.contains("AI review: none"), inbox.text)

        let none = try await call(session, "get_review", #"{"pr":"https://github.com/o/r/pull/1"}"#)
        XCTAssertTrue(none.text.contains("has not reviewed this. Call run_review with pr o/r#1"), none.text)

        let started = try await call(session, "run_review", #"{"pr":"o/r#1"}"#)
        XCTAssertFalse(started.isError, started.text)
        XCTAssertTrue(started.text.contains("call get_review"), started.text)
        XCTAssertEqual(runtime.queue.reviews["PR_1"]?.status.isInFlight, true, "\(String(describing: runtime.queue.reviews["PR_1"]?.status))")

        let bad = try await call(session, "get_review", #"{"pr":"not a pr"}"#)
        XCTAssertTrue(bad.isError)
        await session.close()
    }

    /// The server applies `agents:`, so an agent is refused even though the
    /// adapter itself has no idea what the policy says.
    func testAgentPolicyIsEnforcedByTheServer() async throws {
        let runtime = try startServer()
        try "agents:\n  review: off\n".write(to: dir.appendingPathComponent("prbar.yaml"), atomically: true, encoding: .utf8)
        runtime.repoConfigs.reloadIfChanged()
        XCTAssertEqual(runtime.repoConfigs.config.agents.review, .off)

        let session = MCPSession(socketURL: socketURL)
        let refused = try await call(session, "run_review", #"{"pr":"o/r#1"}"#)
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("agents.review is off"), refused.text)
        XCTAssertNil(runtime.queue.reviews["PR_1"])

        // Reading is still allowed, and the user's own CLI isn't an agent.
        let read = try await call(session, "status")
        XCTAssertFalse(read.isError, read.text)
        let cli = try await ServerConnection.connect(socketURL: socketURL, client: "prbar-review").client
        defer { cli.close() }
        _ = try await cli.call(.runReview, RunReviewParams(pr: PRReference(nodeId: "PR_1")), as: ReviewResult.self)
        XCTAssertNotNil(runtime.queue.reviews["PR_1"])
        await session.close()
    }

    /// The case found by hand: with AI review off for the repo, an agent's
    /// run_review used to queue a real, billed review anyway.
    func testRunReviewRespectsTheRepoOptOut() async throws {
        let runtime = try startServer()
        try "defaults:\n  aiReviewEnabled: false\n".write(to: dir.appendingPathComponent("prbar.yaml"), atomically: true, encoding: .utf8)
        runtime.repoConfigs.reloadIfChanged()
        let session = MCPSession(socketURL: socketURL)
        for args in [#"{"pr":"o/r#1"}"#, #"{"pr":"o/r#1","force":true}"#] {
            let refused = try await call(session, "run_review", args)
            XCTAssertTrue(refused.isError, refused.text)
            XCTAssertTrue(refused.text.contains("AI review is turned off"), refused.text)
        }
        XCTAssertNil(runtime.queue.reviews["PR_1"])
        await session.close()
    }

    /// A PR leaves the inbox once it's merged or the user reviewed it, but
    /// PRBar's review of it is still in the history.
    func testGetReviewFindsAReviewOfAPRNoLongerInTheInbox() async throws {
        let runtime = try startServer(prs: [])
        let pr = RuntimeFixtures.requestedPR()
        runtime.reviewLog.recordCompleted(
            pr: pr, headSha: pr.headSha, providerId: .claude, triggeredAt: Date(),
            review: Self.review(annotations: [
                DiffAnnotation(path: "a.swift", lineStart: 10, lineEnd: 12, severity: .blocker, title: "Crash", body: "Force unwrap."),
            ]))
        let session = MCPSession(socketURL: socketURL)
        let found = try await call(session, "get_review", #"{"pr":"o/r#1"}"#)
        XCTAssertFalse(found.isError, found.text)
        XCTAssertTrue(found.text.contains("[blocker] a.swift:10-12 Crash"), found.text)
        await session.close()
    }

    func testUnknownArgumentsAreRefused() async throws {
        try startServer()
        let session = MCPSession(socketURL: socketURL)
        let typo = try await call(session, "list_inbox", #"{"filtr":"mine"}"#)
        XCTAssertTrue(typo.isError, typo.text)
        XCTAssertTrue(typo.text.contains("filtr"), typo.text)
        XCTAssertTrue(typo.text.contains("filter"), "names the arguments it takes: \(typo.text)")
        await session.close()
    }

    func testABadValueSaysWhatIsAllowed() async throws {
        try startServer()
        let session = MCPSession(socketURL: socketURL)
        let bad = try await call(session, "list_inbox", #"{"filter":"bogus"}"#)
        XCTAssertTrue(bad.isError, bad.text)
        XCTAssertTrue(bad.text.contains("all, review_requested, mine"), bad.text)
        XCTAssertFalse(bad.text.contains("CodingKeys"), bad.text)
        let wrongType = try await call(session, "get_history", #"{"limit":"ten"}"#)
        XCTAssertTrue(wrongType.isError, wrongType.text)
        XCTAssertTrue(wrongType.text.contains("limit must be an integer"), wrongType.text)
        await session.close()
    }

    /// Without a title the headline is the body's first sentence, so
    /// printing both said it twice.
    func testAFindingWithoutATitleIsNotRepeated() {
        let pr = RuntimeFixtures.requestedPR()
        let review = Self.review(annotations: [
            DiffAnnotation(path: "a.swift", lineStart: 1, lineEnd: 1, severity: .warning, title: nil, body: "Leaks the handle"),
        ])
        let state = ReviewState(prNodeId: pr.nodeId, headSha: pr.headSha, triggeredAt: Date(), status: .completed(review), costUsd: 0)
        let text = MCPText.review(ReviewResult(pr: pr, review: state))
        XCTAssertEqual(text.components(separatedBy: "Leaks the handle").count - 1, 1, text)
    }

    func testWatchWaitsForTheReviewToFinish() async throws {
        let runtime = try startServer()
        runtime.queue.providerLookup = { _ in StubReviewProvider() }
        let session = MCPSession(socketURL: socketURL)
        let idle = try await call(session, "watch", #"{"timeout_seconds":1}"#)
        XCTAssertFalse(idle.isError, idle.text)
        XCTAssertTrue(idle.text.contains("Nothing happened in 1s"), idle.text)
        let cursor = try XCTUnwrap(Int(String(idle.text.components(separatedBy: "cursor: ").last?.prefix { $0.isNumber } ?? "")), idle.text)

        // The review may finish before the next watch starts: the cursor
        // is what keeps that from being missed.
        _ = try await call(session, "run_review", #"{"pr":"o/r#1"}"#)
        let news = try await call(session, "watch", #"{"pr":"o/r#1","since":\#(cursor),"timeout_seconds":30}"#)
        XCTAssertTrue(news.text.contains("review finished: o/r#1, Approve"), news.text)
        XCTAssertTrue(news.text.contains("Next: get_review"), news.text)
        await session.close()
    }

    func testArgumentTypesAreChecked() async throws {
        try startServer()
        let session = MCPSession(socketURL: socketURL)
        let flag = try await call(session, "get_history", #"{"limit":true}"#)
        XCTAssertTrue(flag.text.contains("limit must be an integer"), flag.text)
        let number = try await call(session, "get_review", #"{"pr":"o/r#1","full":1}"#)
        XCTAssertTrue(number.text.contains("full must be a boolean"), number.text)
        let none = try await call(session, "status", #"{"verbose":true}"#)
        XCTAssertTrue(none.text.contains("status takes no arguments"), none.text)
        await session.close()
    }

    func testStatusSaysWhatAgentsMayDo() async throws {
        try startServer()
        let session = MCPSession(socketURL: socketURL)
        let status = try await call(session, "status")
        XCTAssertTrue(status.text.contains("agents:     read allow, review allow, post ask, merge off"), status.text)
        await session.close()
    }

    func testInboxLeadsWithCountsAndSaysWhenEmpty() async throws {
        try startServer()
        let session = MCPSession(socketURL: socketURL)
        let inbox = try await call(session, "list_inbox")
        XCTAssertTrue(inbox.text.hasPrefix("1 pull request: 1 awaiting the user's review, 0 authored by the user."), inbox.text)
        XCTAssertFalse(inbox.text.contains("https://"), "no per-PR URLs: \(inbox.text)")
        let mine = try await call(session, "list_inbox", #"{"filter":"mine"}"#)
        XCTAssertEqual(mine.text, "The user has no open pull requests.")
        await session.close()
    }

    func testLongTextIsCutShortUnlessFull() {
        let pr = RuntimeFixtures.requestedPR()
        let long = String(repeating: "word ", count: 400)
        let review = Self.review(annotations: [
            DiffAnnotation(path: "a.swift", lineStart: 1, lineEnd: 1, severity: .warning, title: "Long", body: long),
        ])
        let state = ReviewState(prNodeId: pr.nodeId, headSha: pr.headSha, triggeredAt: Date(), status: .completed(review), costUsd: 0)
        let short = MCPText.review(ReviewResult(pr: pr, review: state))
        XCTAssertTrue(short.contains("[cut short]"), short)
        XCTAssertTrue(short.contains("get_review with full true"), short)
        let whole = MCPText.review(ReviewResult(pr: pr, review: state), full: true)
        XCTAssertFalse(whole.contains("[cut short]"))
        XCTAssertGreaterThan(whole.count, long.count)
    }

    static func review(annotations: [DiffAnnotation]) -> AggregatedReview {
        AggregatedReview(
            verdict: .requestChanges, confidence: 0.9, summaryMarkdown: "Problems.", annotations: annotations,
            costUsd: 0.1, toolCallCount: 0, toolNamesUsed: [], perSubreview: [], isSubscriptionAuth: false)
    }

    func testReviewTextListsFindings() {
        let pr = RuntimeFixtures.requestedPR()
        let review = AggregatedReview(
            verdict: .requestChanges, confidence: 0.9,
            summaryMarkdown: "Two problems.",
            annotations: [
                DiffAnnotation(path: "b.swift", lineStart: 3, lineEnd: 3, severity: .suggestion, title: "Rename", body: "Clearer name."),
                DiffAnnotation(path: "a.swift", lineStart: 10, lineEnd: 12, severity: .blocker, title: "Crash", body: "Force unwrap\non nil."),
            ],
            costUsd: 0.42, toolCallCount: 0, toolNamesUsed: [], perSubreview: [], isSubscriptionAuth: false)
        let state = ReviewState(prNodeId: pr.nodeId, headSha: pr.headSha, triggeredAt: Date(), status: .completed(review), costUsd: 0.42)
        let text = MCPText.review(ReviewResult(pr: pr, review: state))
        XCTAssertTrue(text.contains("Request changes, confidence 0.90, $0.42"), text)
        XCTAssertTrue(text.contains("Findings (2):"), text)
        let blocker = try! XCTUnwrap(text.range(of: "- [blocker] a.swift:10-12 Crash\n  Force unwrap\n  on nil."))
        let suggestion = try! XCTUnwrap(text.range(of: "- [suggestion] b.swift:3 Rename"))
        XCTAssertLessThan(blocker.lowerBound, suggestion.lowerBound, "most severe first")
        XCTAssertEqual(MCPText.stateLine(state, headSha: pr.headSha), "Request changes, 2 findings (1 blocker, 1 suggestion)")
        XCTAssertEqual(MCPText.stateLine(state, headSha: "other"), "Request changes, 2 findings (1 blocker, 1 suggestion) (of an older commit)")
    }
}

final class AgentPolicyTests: XCTestCase {
    func testDefaultsAndSparseEncoding() throws {
        let config = try ConfigFile.decode("version: 1\n").config
        XCTAssertEqual(config.agents, AgentPolicy())
        XCTAssertEqual(config.agents.read, .allow)
        XCTAssertEqual(config.agents.post, .ask)
        XCTAssertEqual(config.agents.merge, .off)
        XCTAssertFalse(try ConfigFile.encode(config).contains("agents"))

        var changed = config
        changed.agents.merge = .ask
        let text = try ConfigFile.encode(changed)
        XCTAssertTrue(text.contains("agents:\n  merge: ask"), text)
        XCTAssertEqual(try ConfigFile.decode(text).config.agents, changed.agents)
    }

    /// For a permission a typo must not grant more than was written.
    func testUnparseableValueTurnsTheCapabilityOff() throws {
        let loaded = try ConfigFile.decode("agents:\n  read: yes-please\n  bogus: allow\n")
        XCTAssertEqual(loaded.config.agents.read, .off)
        XCTAssertEqual(loaded.config.agents.review, .allow)
        XCTAssertTrue(loaded.warnings.contains { $0.contains("agents.bogus") }, "\(loaded.warnings)")
    }

    func testDenials() {
        let agent = HelloParams(client: "mcp:x", protocolVersion: 1, agent: true)
        var policy = AgentPolicy()
        XCTAssertNil(APIServer.denial(of: .status, by: agent, under: policy))
        XCTAssertNil(APIServer.denial(of: .runReview, by: agent, under: policy))
        XCTAssertEqual(APIServer.denial(of: .shutdown, by: agent, under: policy)?.code, RPCError.notPermitted)
        policy.review = .ask
        XCTAssertTrue(APIServer.denial(of: .runReview, by: agent, under: policy)?.message.contains("`ask`") ?? false)
        policy.read = .off
        XCTAssertEqual(APIServer.denial(of: .inbox, by: agent, under: policy)?.code, RPCError.notPermitted)
    }
}
