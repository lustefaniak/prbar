import XCTest
@testable import PRBarCore

/// Rules through a real server: a skip the CLI reports, `rules.explain`,
/// the MCP tool, and `rules check`.
@MainActor
final class RulesServerTests: XCTestCase {
    private var dir: URL!
    private var socketURL: URL!

    override func setUp() async throws {
        dir = URL(fileURLWithPath: "/tmp/prbar-rs-\(UUID().uuidString.prefix(8))")
        socketURL = dir.appendingPathComponent("server.sock")
        try write("lists.yaml", "bots: [a]\n")
        try write("select/10-bots.yaml", """
            name: select
            rule:
              match:
                - condition: pr.author in lists.bots && pr.additions < 10
                  output: '{"rule": "small-bot-changes", "action": "skip", "reason": "a bot, and small"}'
            """)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = dir.appendingPathComponent("rules").appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func startServer() throws -> PRBarRuntime {
        let runtime = RuntimeFixtures.make(dir, ownsAutomation: false, prs: [], github: [RuntimeFixtures.requestedPR()])
        runtime.queue.providerLookup = { _ in StubReviewProvider() }
        let server = APIServer(runtime: runtime, holder: "test", build: "dev")
        try server.start(socketURL: socketURL)
        addTeardownBlock { @MainActor in server.stop() }
        return runtime
    }

    private func connect() async throws -> APIClient {
        try await ServerConnection.connect(socketURL: socketURL, client: "test").client
    }

    func testARuleSkipReachesTheCommandLine() async throws {
        let runtime = try startServer()
        XCTAssertEqual(runtime.repoConfigs.config.compiledRules?.select.count, 1)
        let socket = socketURL!
        var run = ClientReview(
            invocation: try XCTUnwrap(Invocation(args: ["o/r#1"])), configFile: nil,
            connect: { try await ServerConnection.connect(socketURL: socket, client: "prbar-review") })
        var events: [BrahmandaEvent] = []
        run.emit = { events.append($0) }
        run.log = { _ in }
        run.pollInterval = .milliseconds(20)
        _ = await run.run()
        XCTAssertEqual(events.last?.note, "skipped: a bot, and small")
        guard case .skipped(.rule("small-bot-changes", _))? = runtime.queue.reviews["PR_1"]?.status else {
            return XCTFail("\(String(describing: runtime.queue.reviews["PR_1"]))")
        }
    }

    func testExplainShowsTheConditionTheFactsAndTheOutcome() async throws {
        try startServer()
        let client = try await connect()
        defer { client.close() }
        let explanation = try await client.call(
            .explainRules, ExplainRulesParams(pr: PRReference(owner: "o", repo: "r", number: 1)), as: RulesExplanation.self)
        let text = RulesCommand.describe(explanation)
        XCTAssertTrue(text.contains("10-bots.yaml:4:18"), text)
        XCTAssertTrue(text.contains(#"pr.author = "a""#), text)
        XCTAssertTrue(text.contains("matched: small-bot-changes: skip (a bot, and small)"), text)
        XCTAssertTrue(text.contains("Outcome: skipped. The rule `small-bot-changes` skips it: a bot, and small."), text)
        XCTAssertTrue(text.contains("nothing to decide yet"), text)
    }

    func testMCPExplainRules() async throws {
        try startServer()
        let session = MCPSession(socketURL: socketURL)
        let raw = await session.handle(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"explain_rules","arguments":{"pr":"o/r#1"}}}"#.utf8))
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(raw)) as? [String: Any])
        let content = try XCTUnwrap((reply["result"] as? [String: Any])?["content"] as? [[String: Any]], "\(reply)")
        let text = content.compactMap { $0["text"] as? String }.joined()
        XCTAssertTrue(text.contains("small-bot-changes"), text)
        await session.close()
    }

    func testCheck() async throws {
        let env = ["PRBAR_CONFIG": dir.appendingPathComponent("prbar.yaml").path]
        try "{}\n".write(to: dir.appendingPathComponent("prbar.yaml"), atomically: true, encoding: .utf8)
        var out: [String] = []
        var errors: [String] = []
        var code = await RulesCommand.check(configPath: nil).run(environment: env, print: { out.append($0) }, fail: { errors.append($0) })
        XCTAssertEqual(code, 0, errors.joined())
        XCTAssertTrue(out.joined().contains("select: 10-bots.yaml"), out.joined())

        try write("decide/10.yaml", "name: decide\nrule:\n  match:\n    - condition: review.nope\n      output: '{}'\n")
        code = await RulesCommand.check(configPath: nil).run(environment: env, print: { out.append($0) }, fail: { errors.append($0) })
        XCTAssertEqual(code, 1)
        XCTAssertTrue(errors.joined().contains("decide/10.yaml:4:"), errors.joined())
        XCTAssertEqual(RulesCommand(args: ["rules", "explain", "o/r#1"]), .explain(PRReference(owner: "o", repo: "r", number: 1), configPath: nil))
    }
}
