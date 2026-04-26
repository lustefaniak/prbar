import XCTest
@testable import PRBar

/// Tests RepoCheckoutManager against a local fixture repo (no network,
/// no gh auth required). Verifies the bare-clone + worktree-add +
/// worktree-remove lifecycle on a controlled input.
final class RepoCheckoutManagerTests: XCTestCase {
    private var fixtureRoot: URL!
    private var fixtureRepoPath: URL!
    private var fixtureRepoBare: URL!
    private var managerStorage: URL!
    private var commitSha: String!

    override func setUp() async throws {
        try await super.setUp()
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("prbar-checkout-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        managerStorage = fixtureRoot.appendingPathComponent("storage")

        // Build a tiny fixture repo: init, commit one file.
        fixtureRepoPath = fixtureRoot.appendingPathComponent("source-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRepoPath, withIntermediateDirectories: true)
        try await runGit(in: fixtureRepoPath, ["init", "-q", "-b", "main"])
        try await runGit(in: fixtureRepoPath, ["config", "user.email", "test@local"])
        try await runGit(in: fixtureRepoPath, ["config", "user.name", "Test"])
        try "hello\n".write(to: fixtureRepoPath.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await runGit(in: fixtureRepoPath, ["add", "README.md"])
        try await runGit(in: fixtureRepoPath, ["commit", "-q", "-m", "initial"])
        commitSha = try await capturedGit(in: fixtureRepoPath, ["rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Make a bare clone so we can simulate the gh-clone result. We then
        // pre-populate the manager's expected bare path, skipping the gh
        // network roundtrip — that way the test runs offline.
        fixtureRepoBare = fixtureRoot.appendingPathComponent("source.git", isDirectory: true)
        try await runGit(in: fixtureRoot, [
            "clone", "--bare", "--no-local", "--depth=50",
            fixtureRepoPath.path, fixtureRepoBare.path,
        ])
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fixtureRoot)
        try await super.tearDown()
    }

    /// Pre-populate the manager's bare-clone slot from our fixture so the
    /// real `gh repo clone` is never invoked during the test.
    private func seedBareClone(manager: RepoCheckoutManager, owner: String, repo: String) async throws {
        let target = await manager.barePath(owner: owner, repo: repo)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: fixtureRepoBare, to: target)
    }

    func testProvisionReturnsValidWorktreeAtHeadSha() async throws {
        let manager = RepoCheckoutManager(storageBase: managerStorage)
        try await seedBareClone(manager: manager, owner: "fixture", repo: "test")

        let handle = try await manager.provision(
            owner: "fixture", repo: "test",
            headSha: commitSha, subpath: ""
        )

        // Worktree should exist on disk and contain README.md from the commit.
        XCTAssertTrue(FileManager.default.fileExists(atPath: handle.workdir.path))
        let readme = handle.workdir.appendingPathComponent("README.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: readme.path))
        let content = try String(contentsOf: readme, encoding: .utf8)
        XCTAssertEqual(content, "hello\n")

        await manager.release(handle)
    }

    func testProvisionWithSubpathReturnsSubdirectory() async throws {
        // Add a subdirectory to the fixture and commit it.
        let kernelDir = fixtureRepoPath.appendingPathComponent("kernel-billing/audit")
        try FileManager.default.createDirectory(at: kernelDir, withIntermediateDirectories: true)
        try "package audit\n".write(
            to: kernelDir.appendingPathComponent("log.go"),
            atomically: true, encoding: .utf8
        )
        try await runGit(in: fixtureRepoPath, ["add", "."])
        try await runGit(in: fixtureRepoPath, ["commit", "-q", "-m", "add audit"])
        let newSha = try await capturedGit(in: fixtureRepoPath, ["rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Re-build the bare clone to include the new commit.
        try? FileManager.default.removeItem(at: fixtureRepoBare)
        try await runGit(in: fixtureRoot, [
            "clone", "--bare", "--no-local", "--depth=50",
            fixtureRepoPath.path, fixtureRepoBare.path,
        ])

        let manager = RepoCheckoutManager(storageBase: managerStorage)
        try await seedBareClone(manager: manager, owner: "fixture", repo: "test")

        let handle = try await manager.provision(
            owner: "fixture", repo: "test",
            headSha: newSha, subpath: "kernel-billing"
        )

        XCTAssertEqual(handle.workdir.lastPathComponent, "kernel-billing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: handle.workdir.path))
        let log = handle.workdir.appendingPathComponent("audit/log.go")
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path))

        await manager.release(handle)
    }

    func testReleaseRemovesWorktree() async throws {
        let manager = RepoCheckoutManager(storageBase: managerStorage)
        try await seedBareClone(manager: manager, owner: "fixture", repo: "test")

        let handle = try await manager.provision(
            owner: "fixture", repo: "test",
            headSha: commitSha, subpath: ""
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: handle.worktreePath.path))

        await manager.release(handle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: handle.worktreePath.path),
            "worktree dir should be gone after release")
    }

    func testReleaseIsIdempotent() async throws {
        let manager = RepoCheckoutManager(storageBase: managerStorage)
        try await seedBareClone(manager: manager, owner: "fixture", repo: "test")
        let handle = try await manager.provision(
            owner: "fixture", repo: "test",
            headSha: commitSha, subpath: ""
        )
        await manager.release(handle)
        // Second release should not throw.
        await manager.release(handle)
    }

    func testTwoProvisionsForSameShaProduceDistinctWorktrees() async throws {
        let manager = RepoCheckoutManager(storageBase: managerStorage)
        try await seedBareClone(manager: manager, owner: "fixture", repo: "test")

        let h1 = try await manager.provision(
            owner: "fixture", repo: "test", headSha: commitSha, subpath: ""
        )
        let h2 = try await manager.provision(
            owner: "fixture", repo: "test", headSha: commitSha, subpath: ""
        )
        XCTAssertNotEqual(h1.worktreePath, h2.worktreePath,
            "concurrent reviews of the same SHA must use different worktree dirs")

        await manager.release(h1)
        await manager.release(h2)
    }

    // MARK: - helpers

    private func runGit(in cwd: URL, _ args: [String]) async throws {
        let result = try await ProcessRunner.run(
            executable: ExecutableResolver.find("git") ?? "/usr/bin/git",
            args: args,
            cwd: cwd
        )
        if !result.succeeded {
            XCTFail("git \(args.joined(separator: " ")) failed: \(result.stderrString ?? "")")
        }
    }

    private func capturedGit(in cwd: URL, _ args: [String]) async throws -> String {
        let result = try await ProcessRunner.run(
            executable: ExecutableResolver.find("git") ?? "/usr/bin/git",
            args: args,
            cwd: cwd
        )
        return result.stdoutString ?? ""
    }
}
