import XCTest
@testable import PRBarCore

/// What a coding agent may and may not make PRBar do.
@MainActor
final class AgentPermissionTests: XCTestCase {
    private func config(_ edit: (inout ReviewDefaults) -> Void = { _ in }) -> ResolvedRepoConfig {
        var defaults = ReviewDefaults()
        edit(&defaults)
        return RepoConfig.default.resolved(with: defaults)
    }

    /// The repo's own opt-outs are the user's cost decision: `force` can't
    /// lift them for an agent. Softer skips refuse with the reason unless
    /// forced.
    func testAgentReviewRefusals() {
        let pr = RuntimeFixtures.requestedPR()
        let aiOff = APIServer.agentReviewRefusal(pr: pr, config: config { $0.aiReviewEnabled = false }, existing: nil, force: true)
        XCTAssertEqual(aiOff?.code, RPCError.refused)
        XCTAssertTrue(aiOff?.message.contains("AI review is turned off") ?? false, aiOff?.message ?? "")

        let draft = RuntimeFixtures.requestedPR(isDraft: true)
        XCTAssertNotNil(APIServer.agentReviewRefusal(pr: draft, config: config { $0.reviewDrafts = false }, existing: nil, force: false))
        XCTAssertNil(APIServer.agentReviewRefusal(pr: draft, config: config { $0.reviewDrafts = false }, existing: nil, force: true))

        let failed = ReviewState(prNodeId: pr.nodeId, headSha: pr.headSha, triggeredAt: Date(), status: .failed("boom"), costUsd: 0)
        XCTAssertNotNil(APIServer.agentReviewRefusal(pr: pr, config: config(), existing: failed, force: false))
        XCTAssertNil(APIServer.agentReviewRefusal(pr: pr, config: config(), existing: failed, force: true))

        XCTAssertNil(APIServer.agentReviewRefusal(pr: pr, config: config(), existing: nil, force: false))
    }

    func testRequestsBeforeHelloAreRefused() async throws {
        let (_, _, socket) = try makeServer()
        let raw = try APIClient.connect(socketURL: socket)
        defer { raw.close() }
        do {
            _ = try await raw.call(.status, as: ServerStatus.self)
            XCTFail("expected invalidRequest")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, RPCError.invalidRequest)
        }
    }

    /// Retrying a failed merge is merging: it needs `agents.merge`, not
    /// `agents.post`.
    func testRetryNeedsTheCapabilityOfTheRetriedAction() async throws {
        let (runtime, dir, socket) = try makeServer()
        try "agents:\n  post: allow\n  merge: \"off\"\n".write(to: dir.appendingPathComponent("prbar.yaml"), atomically: true, encoding: .utf8)
        runtime.repoConfigs.reloadIfChanged()
        runtime.actionQueue.autoRetryDelays = []
        runtime.actionQueue.mergeExecutor = { _, _ in throw RPCError(code: 1, message: "merge failed") }
        runtime.actionQueue.enqueue(RuntimeFixtures.requestedPR(), kind: .merge(method: .squash))
        for _ in 0..<100 where runtime.actionQueue.state(for: "PR_1")?.failureMessage == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(runtime.actionQueue.state(for: "PR_1")?.failureMessage)

        let agent = try await ServerConnection.connect(socketURL: socket, client: "mcp:test", agent: true).client
        defer { agent.close() }
        for method in [APIMethod.retryAction, .dismissAction] {
            do {
                _ = try await agent.call(method, ActionTarget(prNodeId: "PR_1"), as: APIEmpty.self)
                XCTFail("expected notPermitted for \(method.rawValue)")
            } catch let error as RPCError {
                XCTAssertEqual(error.code, RPCError.notPermitted, method.rawValue)
            }
        }
        XCTAssertNotNil(runtime.actionQueue.state(for: "PR_1")?.failureMessage, "the failed merge is still there")
    }

    private func makeServer() throws -> (PRBarRuntime, URL, URL) {
        let dir = URL(fileURLWithPath: "/tmp/prbar-perm-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let runtime = RuntimeFixtures.make(dir, ownsAutomation: false, prs: [RuntimeFixtures.requestedPR()])
        let server = APIServer(runtime: runtime, holder: "test", build: "dev")
        let socket = dir.appendingPathComponent("server.sock")
        try server.start(socketURL: socket)
        addTeardownBlock { @MainActor in server.stop() }
        return (runtime, dir, socket)
    }
}
