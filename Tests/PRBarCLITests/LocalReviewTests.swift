import XCTest
@testable import PRBarCore

/// Reviewing a working directory: a real repository, a real server.
@MainActor
final class LocalReviewTests: XCTestCase {
    private var dir: URL!
    private var repo: URL!
    private var socketURL: URL!

    override func setUp() async throws {
        dir = URL(fileURLWithPath: "/tmp/prbar-lr-\(UUID().uuidString.prefix(8))")
        repo = dir.appendingPathComponent("checkout")
        socketURL = dir.appendingPathComponent("server.sock")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await sh("git init -q -b main")
        try await sh("git config user.email t@t && git config user.name t && git config commit.gpgsign false")
        try await sh("git remote add origin git@github.com:o/r.git")
        try "a\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "ignored.log\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try await sh("git add -A && git commit -q -m base && git checkout -q -b feature")
        // Work in progress: a tracked edit, an untracked file, an ignored one.
        try "a\nb\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try "noise\n".write(to: repo.appendingPathComponent("ignored.log"), atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func sh(_ command: String) async throws -> String {
        let result = try await ProcessRunner.run(executable: "/bin/sh", args: ["-c", command], cwd: repo)
        guard result.succeeded else {
            throw NSError(domain: "sh", code: Int(result.exitCode), userInfo: [NSLocalizedDescriptionKey: "\(command): \(result.stderrString ?? "")"])
        }
        return (result.stdoutString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testTheSnapshotHoldsTheWorkInProgressAndTouchesNothing() async throws {
        let statusBefore = try await sh("git status --porcelain")
        let snapshot = try await LocalChanges.snapshot(at: repo.appendingPathComponent(".").path)
        XCTAssertEqual(snapshot.owner, "o")
        XCTAssertEqual(snapshot.repo, "r")
        XCTAssertEqual(snapshot.branch, "feature")
        XCTAssertEqual(snapshot.baseRef, "main")
        XCTAssertEqual(snapshot.changedFiles, 2, "the edit and the untracked file, not the ignored one")
        let diff = try await LocalChanges.diff(snapshot)
        XCTAssertTrue(diff.contains("+b"))
        XCTAssertTrue(diff.contains("new.txt"))
        XCTAssertFalse(diff.contains("ignored.log"))

        let after = try await sh("git status --porcelain")
        XCTAssertEqual(after, statusBefore, "the user's index and worktree are untouched")
        let again = try await LocalChanges.snapshot(at: repo.path)
        XCTAssertEqual(again.headSha, snapshot.headSha, "the same changes give the same commit")

        let handle = try await LocalChanges.checkout(snapshot, under: dir.appendingPathComponent("worktrees"))
        XCTAssertEqual(try String(contentsOf: handle.worktreePath.appendingPathComponent("new.txt"), encoding: .utf8), "new\n")
        await LocalChanges.release(handle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: handle.worktreePath.path))
        let worktrees = try await sh("git worktree list")
        XCTAssertEqual(worktrees.split(separator: "\n").count, 1, worktrees)
    }

    func testGitHubSlugs() {
        XCTAssertTrue(LocalChanges.gitHubSlug("git@github.com:o/r.git")! == ("o", "r"))
        XCTAssertTrue(LocalChanges.gitHubSlug("https://github.com/o/r")! == ("o", "r"))
        XCTAssertTrue(LocalChanges.gitHubSlug("ssh://git@github.com/o/r.git")! == ("o", "r"))
        XCTAssertNil(LocalChanges.gitHubSlug("git@gitlab.com:o/r.git"))
    }

    func testCommandLineReviewThroughTheServer() async throws {
        let (runtime, prompts) = try startServer()
        var printed: [String] = []
        var command = LocalReviewCommand(
            options: try XCTUnwrap(LocalReviewCommand.Options(args: [repo.path])),
            connect: connect)
        command.print = { printed.append($0) }
        command.log = { _ in }
        command.pollInterval = .milliseconds(20)
        let code = await command.run()
        XCTAssertEqual(code, 0)
        let text = printed.joined()
        XCTAssertTrue(text.hasPrefix("Review of local changes on feature against main, by claude: Approve"), text)
        let prompt = await prompts.first ?? ""
        XCTAssertTrue(prompt.contains("not a pull request yet"), prompt)
        XCTAssertTrue(prompt.contains("`feature`, compared with `main`"), prompt)
        XCTAssertEqual(runtime.actionLog.entries.count, 0, "nothing is posted")

        // The same changes again: answered from the first review.
        let result = try await connect().client.call(.reviewLocal, LocalReviewParams(path: repo.path), as: ReviewResult.self)
        if case .completed = result.review?.status {} else { XCTFail("\(String(describing: result.review?.status))") }
        let calls = await prompts.count
        XCTAssertEqual(calls, 1)
    }

    func testNothingToReview() async throws {
        try startServer()
        try await sh("git stash -u -q")
        let result = try await connect().client.call(.reviewLocal, LocalReviewParams(path: repo.path), as: ReviewResult.self)
        XCTAssertEqual(result.ignored, "no changes against main")
    }

    func testMCPRunAndGetByPath() async throws {
        try startServer()
        let session = MCPSession(socketURL: socketURL)
        // Named by the repository root as git reports it (/private/tmp).
        let root = try await LocalChanges.root(of: repo.path)
        let started = try await call(session, "run_review", #"{"path":"\#(repo.path)"}"#)
        XCTAssertTrue(started.contains("watch with path \(root)"), started)
        let watched = try await call(session, "watch", #"{"path":"\#(repo.path)","since":0,"timeout_seconds":20}"#)
        XCTAssertTrue(watched.contains("review finished: \(root), Approve"), watched)
        let review = try await call(session, "get_review", #"{"path":"\#(repo.path)"}"#)
        XCTAssertTrue(review.hasPrefix("Local changes in \(root) on feature, against main"), review)
        let both = try await call(session, "get_review", #"{"path":"\#(repo.path)","pr":"o/r#1"}"#)
        XCTAssertEqual(both, "pass pr or path, not both.")
        await session.close()
    }

    // MARK: - Plumbing

    private var connect: @Sendable () async throws -> ServerConnection.Connected {
        let socket = socketURL!
        return { try await ServerConnection.connect(socketURL: socket, client: "prbar-review") }
    }

    @discardableResult
    private func startServer() throws -> (PRBarRuntime, PromptRecorder) {
        let runtime = RuntimeFixtures.make(dir, ownsAutomation: false)
        let prompts = PromptRecorder()
        runtime.queue.providerLookup = { _ in RecordingProvider(prompts: prompts) }
        let server = APIServer(runtime: runtime, holder: "test", build: "dev")
        try server.start(socketURL: socketURL)
        addTeardownBlock { @MainActor in server.stop() }
        return (runtime, prompts)
    }

    private func call(_ session: MCPSession, _ tool: String, _ arguments: String) async throws -> String {
        let raw = await session.handle(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(arguments)}}"#.utf8))
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(raw)) as? [String: Any])
        let content = try XCTUnwrap((reply["result"] as? [String: Any])?["content"] as? [[String: Any]], "\(reply)")
        return content.compactMap { $0["text"] as? String }.joined()
    }
}

actor PromptRecorder {
    private(set) var prompts: [String] = []
    var first: String? { prompts.first }
    var count: Int { prompts.count }
    func record(_ prompt: String) { prompts.append(prompt) }
}

struct RecordingProvider: ReviewProvider {
    let prompts: PromptRecorder
    let id = "claude"
    let displayName = "Claude (recording stub)"
    func availability() async -> ProviderAvailability { .ready }
    func review(
        bundle: PromptBundle, options: ProviderOptions, onProgress: (@Sendable (ReviewProgress) -> Void)?
    ) async throws -> ProviderResult {
        await prompts.record(bundle.userPrompt)
        return ProviderResult(
            verdict: .approve, confidence: 0.99, summaryMarkdown: "fine", annotations: [],
            costUsd: 0.01, toolCallCount: 0, toolNamesUsed: [], rawJson: Data("{}".utf8))
    }
}
