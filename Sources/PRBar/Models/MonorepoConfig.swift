import Foundation

/// How `MonorepoSplitter` handles diff hunks whose file paths don't match
/// any of the config's `rootPatterns`.
enum UnmatchedStrategy: String, Codable, Sendable, Hashable, CaseIterable {
    /// Single subreview with `subpath = ""` covering all unmatched hunks.
    case reviewAtRoot
    /// Drop the unmatched hunks entirely (e.g. for repos where you only
    /// care about kernel changes and want to skip docs-only PRs).
    case skipReview
    /// Single subreview with `subpath = "<other>"` so the unmatched hunks
    /// stay reviewable but visibly separate from a "real" repo-root review.
    case groupAsOther
}

/// Per-repo configuration for the monorepo splitter and per-subreview
/// budget caps. One config per repo glob; the most-specific match wins.
///
/// Phase 4 stores configs in-memory only; persistence to SwiftData lands
/// alongside `ActionLog` later.
struct MonorepoConfig: Sendable, Hashable, Codable {
    /// Glob like "getsynq/cloud" (exact match) or "getsynq/*" (org-wide).
    /// Negations supported: ["getsynq/*", "!getsynq/cloud"].
    let repoGlobs: [String]

    /// Ordered list of fnmatch-style root patterns. Longest literal prefix
    /// wins on ties.
    let rootPatterns: [String]

    let unmatchedStrategy: UnmatchedStrategy

    /// Subreviews with fewer files than this fold into the unmatched
    /// bucket per `unmatchedStrategy`.
    let minFilesPerSubreview: Int

    /// Force a tool mode for this repo (e.g. `.none` for security-sensitive
    /// repos). Nil → use the worker's global default.
    let toolModeOverride: ToolMode?

    /// Cap on the number of subreviews per PR. Excess subreviews (sorted
    /// by file count desc) are tail-merged into the unmatched bucket.
    let maxParallelSubreviews: Int

    let maxToolCallsPerSubreview: Int
    let maxCostUsdPerSubreview: Double

    /// Default for any repo not explicitly configured. Single subreview
    /// at the repo root, conservative caps, no per-subpath splitting.
    static let `default` = MonorepoConfig(
        repoGlobs: ["*/*"],
        rootPatterns: [],
        unmatchedStrategy: .reviewAtRoot,
        minFilesPerSubreview: 1,
        toolModeOverride: nil,
        maxParallelSubreviews: 1,
        maxToolCallsPerSubreview: 10,
        maxCostUsdPerSubreview: 0.30
    )

    /// Bundled default for `getsynq/cloud`. Mirrors the actual top-level
    /// layout: `kernel-*`, `lib/*`, plus the named monorepo apps.
    static let getsynqCloud = MonorepoConfig(
        repoGlobs: ["getsynq/cloud"],
        rootPatterns: [
            "kernel-*", "lib/*",
            "api", "api_public", "app-slack", "fe-app",
            "dev-infra", "dev-tools", "dev-helpers",
            "proto", "proto_public", "playbooks", "Taskfiles",
        ],
        unmatchedStrategy: .reviewAtRoot,
        minFilesPerSubreview: 1,
        toolModeOverride: nil,
        maxParallelSubreviews: 4,
        maxToolCallsPerSubreview: 10,
        maxCostUsdPerSubreview: 0.30
    )

    /// Built-in registry. Picks the first config whose `repoGlobs` match
    /// the given owner/repo (negations honored). Falls back to `.default`.
    static func match(owner: String, repo: String, configs: [MonorepoConfig] = builtins) -> MonorepoConfig {
        let nameWithOwner = "\(owner)/\(repo)"
        for config in configs where config.matches(nameWithOwner: nameWithOwner) {
            return config
        }
        return .default
    }

    /// Built-ins ship with PRBar; user overrides land via Settings later.
    static let builtins: [MonorepoConfig] = [.getsynqCloud]

    func matches(nameWithOwner: String) -> Bool {
        GlobMatcher.anyMatch(repoGlobs, nameWithOwner)
    }
}
