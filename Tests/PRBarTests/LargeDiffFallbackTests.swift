import XCTest
@testable import PRBar

/// GitHub refuses `gh pr diff` above 300 files (HTTP 406, `too_large`).
/// The review must still run, from the diff computed in the local clone.
@MainActor
final class LargeDiffFallbackTests: XCTestCase {
    private var fixtureRoot: URL!
    private var sourceRepo: URL!
    private var headSha: String!

    override func setUp() async throws {
        try await super.setUp()
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("prbar-large-diff-\(UUID().uuidString)", isDirectory: true)
        sourceRepo = fixtureRoot.appendingPathComponent("source-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRepo, withIntermediateDirectories: true)
        try await git(["init", "-q", "-b", "main"])
        try await git(["config", "user.email", "test@local"])
        try await git(["config", "user.name", "Test"])
        try await git(["config", "core.hooksPath", "/dev/null"])
        try write("README.md", "hello\n")
        try await git(["add", "."])
        try await git(["commit", "-q", "-m", "initial"])

        try await git(["checkout", "-q", "-b", "feature"])
        try write("README.md", "hello\nfeature\n")
        try write("added.txt", "new file\n")
        try await git(["add", "."])
        try await git(["commit", "-q", "-m", "feature"])
        headSha = try await git(["rev-parse", "HEAD"])

        // main moves on after the branch: GitHub's diff is against the
        // merge base, so this change must not show up in the PR's diff.
        try await git(["checkout", "-q", "main"])
        try write("later-on-main.txt", "unrelated\n")
        try await git(["add", "."])
        try await git(["commit", "-q", "-m", "later on main"])
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fixtureRoot)
        try await super.tearDown()
    }

    func testTooLargeDiffFallsBackToLocalClone() async throws {
        let manager = RepoCheckoutManager(storageBase: fixtureRoot.appendingPathComponent("storage"))
        let bare = await manager.barePath(owner: "fixture", repo: "test")
        try FileManager.default.createDirectory(
            at: bare.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try await ProcessRunner.run(
            executable: ExecutableResolver.find("git")!,
            args: ["clone", "-q", "--bare", "--no-local", sourceRepo.path, bare.path]
        )

        let worker = ReviewQueueWorker(
            diffFetcher: { _, _, _ in
                throw GHClient.GHError.execFailed(
                    stderr: "could not find pull request diff: HTTP 406: Sorry, the diff exceeded the maximum number of files (300). "
                        + "Consider using 'List pull requests files' API or locally cloning the repository instead. "
                        + "(https://api.github.com/repos/fixture/test/pulls/1)\nPullRequest.diff too_large\n",
                    exitCode: 1)
            },
            checkoutManager: manager
        )
        let provider = BundleCapturingStubProvider(verdict: .comment, summary: "ok", cost: 0)
        worker.provider = provider
        worker.providerLookup = nil
        worker.configResolver = { _, _ in Self.inlineDiffConfig() }

        worker.enqueue(makePR())
        let deadline = Date().addingTimeInterval(30)
        while worker.reviews["PR1"]?.status.isInFlight ?? true, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        guard case .completed = worker.reviews["PR1"]?.status else {
            return XCTFail("review should complete, got \(String(describing: worker.reviews["PR1"]?.status))")
        }
        let prompt = try XCTUnwrap(provider.lastUserPrompt)
        XCTAssertTrue(prompt.contains("+feature"))
        XCTAssertTrue(prompt.contains("added.txt"))
        XCTAssertFalse(prompt.contains("later-on-main.txt"))
    }

    nonisolated private static func inlineDiffConfig() -> ResolvedRepoConfig {
        var rule = RepoConfig.default
        rule.toolModeOverride = ToolMode.none
        return rule.resolved(with: ReviewDefaults())
    }

    private func makePR() -> InboxPR {
        InboxPR(
            nodeId: "PR1", owner: "fixture", repo: "test", number: 1,
            title: "big", body: "", url: URL(string: "https://github.com/fixture/test/pull/1")!,
            author: "a", headRef: "feature", baseRef: "main",
            headSha: headSha, isDraft: false,
            role: .reviewRequested,
            mergeable: "MERGEABLE", mergeStateStatus: "BLOCKED", reviewDecision: nil,
            checkRollupState: "EMPTY",
            totalAdditions: 2, totalDeletions: 0, changedFiles: 301,
            hasAutoMerge: false, autoMergeEnabledBy: nil, allCheckSummaries: [],
            allowedMergeMethods: [.squash], autoMergeAllowed: false, deleteBranchOnMerge: false
        )
    }

    private func write(_ path: String, _ text: String) throws {
        try text.write(to: sourceRepo.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func git(_ args: [String]) async throws -> String {
        let result = try await ProcessRunner.run(
            executable: ExecutableResolver.find("git")!, args: ["-C", sourceRepo.path] + args)
        XCTAssertTrue(result.succeeded, "git \(args) failed: \(result.stderrString ?? "")")
        return (result.stdoutString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
