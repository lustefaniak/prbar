import Foundation

/// Reviewing a working directory instead of a PR: uncommitted changes, or a
/// work-in-progress branch, measured against where it forked from.
///
/// The working tree is captured as a commit first (`snapshot`), so the
/// review reads a fixed state while the user keeps editing, and the rest of
/// the pipeline sees what it always sees: a base SHA, a head SHA and a
/// checkout at the head. The commit is built through a temporary index and
/// never touches the user's index, branch or worktree; it is only an object
/// in their repo, unreferenced, which `git gc` collects.
enum LocalChanges {
    enum Failure: Error, LocalizedError {
        case notARepository(String)
        case noBase(String)
        case git(String, String)

        var errorDescription: String? {
            switch self {
            case .notARepository(let path): return "\(path) is not inside a git repository"
            case .noBase(let tried): return "found no base to compare against (tried \(tried)); pass one with --base"
            case .git(let command, let stderr): return "git \(command) failed: \(stderr.prefix(400))"
            }
        }
    }

    /// One captured state of a working tree.
    struct Snapshot: Codable, Sendable, Hashable {
        /// The repository root.
        var root: String
        var owner: String
        var repo: String
        var branch: String
        var baseRef: String
        var baseSha: String
        /// The commit holding the working tree. Built with fixed authorship
        /// and dates, so unchanged files give the same SHA every time and a
        /// second review of them is answered from the first.
        var headSha: String
        var additions: Int
        var deletions: Int
        var changedFiles: Int

        /// The review slot: one per repository checkout.
        var nodeId: String { Self.nodeId(root: root) }
        static func nodeId(root: String) -> String { "local:\(root)" }
    }

    static func root(of path: String) async throws -> String {
        let dir = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        guard let root = try? await git(["rev-parse", "--show-toplevel"], in: dir) else {
            throw Failure.notARepository(dir.path)
        }
        return root
    }

    static func snapshot(at path: String, base: String? = nil) async throws -> Snapshot {
        let root = try await root(of: path)
        let dir = URL(fileURLWithPath: root)
        let remote = (try? await git(["remote", "get-url", "origin"], in: dir)).flatMap(gitHubSlug)
        let branch = (try? await git(["rev-parse", "--abbrev-ref", "HEAD"], in: dir)) ?? "HEAD"

        var candidates: [String] = []
        if let base {
            candidates = [base]
        } else {
            if let originHead = try? await git(["rev-parse", "--abbrev-ref", "origin/HEAD"], in: dir) {
                candidates.append(originHead)
            }
            candidates += ["origin/main", "origin/master", "main", "master"]
        }
        var resolved: (ref: String, sha: String)?
        for ref in candidates {
            if let sha = try? await git(["merge-base", "HEAD", ref], in: dir) {
                resolved = (ref, sha)
                break
            }
        }
        guard let resolved else { throw Failure.noBase(candidates.joined(separator: ", ")) }

        let headSha = try await captureWorkingTree(in: dir)
        let stat = try await git(["diff", "--shortstat", resolved.sha, headSha], in: dir)
        return Snapshot(
            root: root, owner: remote?.owner ?? "local", repo: remote?.repo ?? dir.lastPathComponent,
            branch: branch, baseRef: resolved.ref, baseSha: resolved.sha, headSha: headSha,
            additions: number(before: "insertion", in: stat),
            deletions: number(before: "deletion", in: stat),
            changedFiles: number(before: "file", in: stat))
    }

    /// Writes the working tree, untracked files included (minus what
    /// `.gitignore` excludes), as a commit on top of HEAD. Starts from a
    /// copy of the real index, so only changed files are hashed.
    static func captureWorkingTree(in dir: URL) async throws -> String {
        let indexPath = try await git(["rev-parse", "--path-format=absolute", "--git-path", "index"], in: dir)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("prbar-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        if FileManager.default.fileExists(atPath: indexPath) {
            try FileManager.default.copyItem(atPath: indexPath, toPath: scratch.path)
        }
        let index = ["GIT_INDEX_FILE": scratch.path]
        _ = try await git(["add", "-A"], in: dir, environment: index)
        let tree = try await git(["write-tree"], in: dir, environment: index)
        let fixed = [
            "GIT_AUTHOR_NAME": "PRBar", "GIT_AUTHOR_EMAIL": "prbar@localhost", "GIT_AUTHOR_DATE": "2000-01-01T00:00:00Z",
            "GIT_COMMITTER_NAME": "PRBar", "GIT_COMMITTER_EMAIL": "prbar@localhost", "GIT_COMMITTER_DATE": "2000-01-01T00:00:00Z",
        ]
        return try await git(["commit-tree", tree, "-p", "HEAD", "-m", "Local changes, captured by PRBar for review"], in: dir, environment: fixed)
    }

    static func diff(_ snapshot: Snapshot) async throws -> String {
        try await git(["diff", snapshot.baseSha, snapshot.headSha], in: URL(fileURLWithPath: snapshot.root), trimming: false)
    }

    /// A checkout of the snapshot in its own worktree, which the review
    /// explores as it would a PR's. `release` removes it, through
    /// `barePath` (the repository's git directory).
    static func checkout(_ snapshot: Snapshot, under directory: URL) async throws -> RepoCheckoutManager.Handle {
        let dir = URL(fileURLWithPath: snapshot.root)
        let gitDir = try await git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: dir)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let worktree = directory.appendingPathComponent("local-\(snapshot.headSha.prefix(8))-\(UUID().uuidString.prefix(8))")
        _ = try await git(["worktree", "add", "--detach", worktree.path, snapshot.headSha], in: dir)
        return RepoCheckoutManager.Handle(
            owner: snapshot.owner, repo: snapshot.repo, headSha: snapshot.headSha, baseSha: snapshot.baseSha,
            barePath: URL(fileURLWithPath: gitDir), worktreePath: worktree, workdir: worktree)
    }

    /// Removes a `checkout`, the worktree's registration in the repository
    /// included.
    static func release(_ handle: RepoCheckoutManager.Handle) async {
        let removed = try? await git(
            ["--git-dir", handle.barePath.path, "worktree", "remove", "--force", handle.worktreePath.path],
            in: handle.barePath)
        if removed == nil {
            try? FileManager.default.removeItem(at: handle.worktreePath)
            _ = try? await git(["--git-dir", handle.barePath.path, "worktree", "prune"], in: handle.barePath)
        }
    }

    /// The PR-shaped value the pipeline takes.
    static func pr(for snapshot: Snapshot) -> InboxPR {
        InboxPR(
            nodeId: snapshot.nodeId, owner: snapshot.owner, repo: snapshot.repo, number: 0,
            title: "Local changes on \(snapshot.branch)", body: "",
            url: URL(fileURLWithPath: snapshot.root),
            author: "", headRef: snapshot.branch, baseRef: snapshot.baseRef,
            headSha: snapshot.headSha, isDraft: false, role: .authored,
            mergeable: "UNKNOWN", mergeStateStatus: "UNKNOWN", reviewDecision: nil,
            checkRollupState: "",
            totalAdditions: snapshot.additions, totalDeletions: snapshot.deletions, changedFiles: snapshot.changedFiles,
            hasAutoMerge: false, autoMergeEnabledBy: nil, allCheckSummaries: [],
            allowedMergeMethods: [], autoMergeAllowed: false, deleteBranchOnMerge: false,
            local: snapshot)
    }

    /// `owner/repo` from a GitHub remote URL (https or ssh).
    static func gitHubSlug(_ url: String) -> (owner: String, repo: String)? {
        var path = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = path.range(of: "github.com") {
            path = String(path[range.upperBound...])
        } else {
            return nil
        }
        path = String(path.drop { $0 == ":" || $0 == "/" })
        if path.hasSuffix(".git") { path.removeLast(4) }
        let parts = path.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    private static func number(before word: String, in stat: String) -> Int {
        // " 3 files changed, 10 insertions(+), 2 deletions(-)"
        for part in stat.split(separator: ",") where part.contains(word) {
            if let n = Int(part.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") { return n }
        }
        return 0
    }

    @discardableResult
    static func git(_ args: [String], in dir: URL, environment: [String: String] = [:], trimming: Bool = true) async throws -> String {
        guard let gitPath = ExecutableResolver.find("git") else { throw Failure.git(args.first ?? "", "git not found") }
        let result = try await ProcessRunner.run(
            executable: gitPath, args: args, cwd: dir,
            environment: ProcessRunner.inheritedEnvironment(overrides: environment))
        guard result.succeeded else {
            throw Failure.git(args.first ?? "", result.stderrString ?? "")
        }
        let out = result.stdoutString ?? ""
        return trimming ? out.trimmingCharacters(in: .whitespacesAndNewlines) : out
    }
}
