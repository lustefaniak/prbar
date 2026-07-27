import Foundation

/// Reads per-file commit counts out of a checkout for `RiskBrief`'s churn
/// term.
enum GitChurn {
    /// Count commits touching each path over a trailing window.
    ///
    /// `--name-only` (not `--numstat`) is deliberate: we only need *how many
    /// commits touched a path*, which is a tree-level diff, so nothing
    /// faults a blob. `RepoCheckoutManager` clones `--filter=blob:none`, and
    /// `--numstat` would pull a blob pair per changed file per commit —
    /// hundreds of MB on a busy repo, for a number we discard anyway.
    ///
    /// `--no-renames` matches code-review-graph: churn belongs to the path
    /// as it existed in each commit, not to wherever it ended up.
    ///
    /// Returns nil when git is missing or the log can't be read. The caller
    /// treats that as "no churn term" — this signal is never load-bearing.
    static func fetch(worktree: URL, windowDays: Int) async -> ChurnWindow? {
        guard windowDays > 0, let git = ExecutableResolver.find("git") else { return nil }
        let env = noLazyFetchEnvironment()

        // `--format=` empties the commit header, so stdout is purely the
        // NUL-separated path list of every commit in the window. Counting
        // occurrences of a path therefore counts (commit, path) pairs =
        // commits touching that path. Commit boundaries are invisible in
        // this form and we don't need them.
        let log = try? await ProcessRunner.run(
            executable: git,
            args: [
                "-C", worktree.path,
                "-c", "core.quotepath=off",
                "log", "--since=\(windowDays).days.ago",
                "--no-renames", "--format=", "--name-only", "-z",
            ],
            environment: env
        )
        guard let log, log.succeeded, let stdout = log.stdoutString else { return nil }

        var counts: [String: Int] = [:]
        for path in stdout.split(separator: "\0", omittingEmptySubsequences: true) {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            counts[trimmed, default: 0] += 1
        }
        guard !counts.isEmpty else { return nil }

        let (observed, span) = await windowShape(
            git: git, worktree: worktree, windowDays: windowDays, environment: env
        )
        return ChurnWindow(commitsByPath: counts, commitsObserved: observed, spanDays: span)
    }

    /// A shallow blobless clone will happily reach out to the promisor
    /// remote mid-`log` if some object is missing. Churn is a nice-to-have
    /// on a hot path, so forbid that: a missing object should make the
    /// command fail fast (we then drop the churn term) rather than block a
    /// review on network.
    ///
    /// `ProcessRunner.childEnvironment` *replaces* the inherited environment
    /// when given an override, so merge rather than pass a bare dictionary —
    /// git without HOME/USER behaves differently enough to matter.
    private static func noLazyFetchEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["GIT_NO_LAZY_FETCH"] = "1"
        return env
    }

    /// How much history the window actually covered. The clone is shallow
    /// (`--depth=50`), so the requested window is an upper bound and often
    /// far off it — `RiskBrief` needs the real numbers to decide whether the
    /// ranking means anything.
    private static func windowShape(
        git: String,
        worktree: URL,
        windowDays: Int,
        environment: [String: String]
    ) async -> (commits: Int, spanDays: Int) {
        let result = try? await ProcessRunner.run(
            executable: git,
            args: [
                "-C", worktree.path,
                "log", "--since=\(windowDays).days.ago", "--format=%ct",
            ],
            environment: environment
        )
        guard let result, result.succeeded, let stdout = result.stdoutString else { return (0, 0) }
        let stamps = stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard let newest = stamps.max(), let oldest = stamps.min() else { return (0, 0) }
        let span = Int(((newest - oldest) / 86_400).rounded())
        return (stamps.count, max(span, 0))
    }
}
