import Foundation

/// Manages the on-disk checkouts that `.minimal` tool mode reviews need.
///
/// One bare clone per repo at:
///   ~/Library/Application Support/io.synq.prbar/repos/<owner>/<repo>.git
///
/// One transient sparse worktree per (repo, headSha) at:
///   ~/Library/Application Support/io.synq.prbar/worktrees/<sha-prefix>-<random>/
///
/// Bare clones use `--filter=blob:none --depth=50` so they stay small —
/// blobs fault in lazily as the AI reads files. Worktrees are torn down
/// after each review.
actor RepoCheckoutManager {
    enum CheckoutError: Error, LocalizedError, Sendable {
        case toolNotFound(String)
        case execFailed(command: String, stderr: String, exitCode: Int32)

        var errorDescription: String? {
            switch self {
            case .toolNotFound(let name):
                return "\(name) not found in PATH."
            case .execFailed(let cmd, let stderr, let code):
                return "\(cmd) exited \(code): \(stderr.prefix(400))"
            }
        }
    }

    let storageBase: URL

    nonisolated var bareReposDir: URL { storageBase.appendingPathComponent("repos") }
    nonisolated var worktreesDir: URL { storageBase.appendingPathComponent("worktrees") }

    static let defaultStorage: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("io.synq.prbar", isDirectory: true)
    }()

    init(storageBase: URL = RepoCheckoutManager.defaultStorage) {
        self.storageBase = storageBase
        try? FileManager.default.createDirectory(at: bareReposDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: worktreesDir, withIntermediateDirectories: true)
    }

    /// Provision a worktree at `headSha`. The returned `Handle.workdir` is
    /// the path the review should `cd` into — either the worktree root
    /// (when `subpath = ""`) or `<worktree>/<subpath>` for monorepo
    /// subreviews.
    ///
    /// First call for a given (owner, repo) does a bare clone (slow,
    /// ~MB-scale). Subsequent calls reuse the bare clone and only fetch
    /// the new SHA.
    func provision(owner: String, repo: String, headSha: String, subpath: String) async throws -> Handle {
        try await ensureBareClone(owner: owner, repo: repo)
        try await fetchSha(owner: owner, repo: repo, headSha: headSha)
        let worktree = try await addWorktree(owner: owner, repo: repo, headSha: headSha)
        let workdir = subpath.isEmpty
            ? worktree
            : worktree.appendingPathComponent(subpath, isDirectory: true)
        return Handle(
            owner: owner,
            repo: repo,
            headSha: headSha,
            barePath: barePath(owner: owner, repo: repo),
            worktreePath: worktree,
            workdir: workdir
        )
    }

    /// Remove the worktree associated with a handle. Idempotent — repeat
    /// calls and missing worktrees are silent. The bare clone is left
    /// alone (reused next time).
    func release(_ handle: Handle) async {
        // `git worktree remove --force` cleans up both the directory and
        // the bare clone's metadata pointer. If git fails for any reason
        // (e.g. worktree was already removed), fall back to rm -rf so we
        // don't leak dirs.
        let result = try? await runGit(args: [
            "--git-dir", handle.barePath.path,
            "worktree", "remove", "--force", handle.worktreePath.path,
        ])
        if result?.succeeded != true {
            try? FileManager.default.removeItem(at: handle.worktreePath)
        }
    }

    /// Total disk used by all bare clones — useful for the Diagnostics tab.
    func totalCacheBytes() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: bareReposDir,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
                .totalFileAllocatedSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    /// Public for tests — used to verify clone existence after first call.
    func barePath(owner: String, repo: String) -> URL {
        bareReposDir
            .appendingPathComponent(owner)
            .appendingPathComponent("\(repo).git", isDirectory: true)
    }

    // MARK: - private

    private func ensureBareClone(owner: String, repo: String) async throws {
        let path = barePath(owner: owner, repo: repo)
        if FileManager.default.fileExists(atPath: path.path) { return }

        let parent = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        // Use `gh repo clone` so private-repo auth flows through gh's token.
        // The `--` separator passes everything after as git options.
        guard let ghPath = ExecutableResolver.find("gh") else {
            throw CheckoutError.toolNotFound("gh")
        }
        let result = try await ProcessRunner.run(
            executable: ghPath,
            args: [
                "repo", "clone", "\(owner)/\(repo)", path.path,
                "--", "--bare", "--depth=50", "--filter=blob:none",
            ]
        )
        guard result.succeeded else {
            throw CheckoutError.execFailed(
                command: "gh repo clone",
                stderr: result.stderrString ?? "",
                exitCode: result.exitCode
            )
        }
    }

    private func fetchSha(owner: String, repo: String, headSha: String) async throws {
        let bare = barePath(owner: owner, repo: repo)
        let result = try await runGit(args: [
            "--git-dir", bare.path,
            "fetch", "origin", headSha,
            "--depth=50", "--filter=blob:none",
        ])
        // Already-have-the-SHA isn't a failure — git reports "fatal:
        // remote error" for unreachable SHAs but exits 0 when no fetch is
        // necessary. Treat any non-success carefully.
        if !result.succeeded {
            // Some servers refuse fetch-by-sha when "uploadpack.allowReachableSHA1InWant"
            // is off. Fall back to a default fetch — slower but always works.
            let fallback = try await runGit(args: [
                "--git-dir", bare.path,
                "fetch", "origin", "--depth=50", "--filter=blob:none",
            ])
            guard fallback.succeeded else {
                throw CheckoutError.execFailed(
                    command: "git fetch",
                    stderr: fallback.stderrString ?? "",
                    exitCode: fallback.exitCode
                )
            }
        }
    }

    private func addWorktree(owner: String, repo: String, headSha: String) async throws -> URL {
        let bare = barePath(owner: owner, repo: repo)
        let suffix = "\(headSha.prefix(12))-\(UUID().uuidString.prefix(8))"
        let worktree = worktreesDir.appendingPathComponent(suffix, isDirectory: true)
        let result = try await runGit(args: [
            "--git-dir", bare.path,
            "worktree", "add", "--detach", worktree.path, headSha,
        ])
        guard result.succeeded else {
            throw CheckoutError.execFailed(
                command: "git worktree add",
                stderr: result.stderrString ?? "",
                exitCode: result.exitCode
            )
        }
        return worktree
    }

    private func runGit(args: [String]) async throws -> ProcessResult {
        guard let gitPath = ExecutableResolver.find("git") else {
            throw CheckoutError.toolNotFound("git")
        }
        return try await ProcessRunner.run(executable: gitPath, args: args)
    }

    /// Handle returned from `provision`. Pass to `release` to tear down
    /// the worktree.
    struct Handle: Sendable, Hashable {
        let owner: String
        let repo: String
        let headSha: String
        let barePath: URL
        let worktreePath: URL
        let workdir: URL
    }
}
