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

/// Whether to fan a PR's diff out across subfolder roots or review the
/// whole thing as one unit.
enum SplitMode: String, Codable, Sendable, Hashable, CaseIterable {
    /// One review per `rootPattern` match.
    case perSubfolder
    /// One review for the whole PR regardless of `rootPatterns`. Useful
    /// when a PR characteristically spans many modules and a per-folder
    /// breakdown would just be noise.
    case single
}

/// Per-repo auto-approve policy. Disabled by default; enabling it on a
/// repo lets the worker fire `gh pr review --approve` automatically when
/// an aggregated AI review meets all gates. A 30 s undo banner shows in
/// the popover before the actual call.
struct AutoApproveConfig: Sendable, Hashable, Codable {
    var enabled: Bool

    /// Aggregated confidence floor (0 to 1). Defaults to 0.85.
    var minConfidence: Double

    /// Reject auto-approval if any annotation is `.warning` or `.blocker`.
    var requireZeroBlockingAnnotations: Bool

    /// Cap on diff size in additions. 0 = unlimited.
    var maxAdditions: Int

    static let off = AutoApproveConfig(
        enabled: false,
        minConfidence: 0.85,
        requireZeroBlockingAnnotations: true,
        maxAdditions: 200
    )
}

/// Per-repo configuration: monorepo splitter shape, prompt overrides,
/// tool-mode override, auto-approve policy, exclusion. One config per
/// `repoGlobs` entry; the most-specific match wins (built-ins as
/// fallback). Persisted as JSON via `RepoConfigStore`.
struct RepoConfig: Sendable, Hashable, Codable {
    /// Glob like "getsynq/cloud" (exact match) or "getsynq/*" (org-wide).
    /// Negations supported: ["getsynq/*", "!getsynq/cloud"].
    var repoGlobs: [String]

    /// If true, PRs from matching repos are skipped entirely — the worker
    /// never enqueues them. Useful for noisy bot repos.
    var excluded: Bool = false

    // --- Splitter ---

    var splitMode: SplitMode = .perSubfolder

    /// Ordered list of fnmatch-style root patterns. Longest literal prefix
    /// wins on ties. Ignored when `splitMode == .single`.
    var rootPatterns: [String]

    var unmatchedStrategy: UnmatchedStrategy

    /// Subreviews with fewer files than this fold into the unmatched
    /// bucket per `unmatchedStrategy`.
    var minFilesPerSubreview: Int

    /// Cap on the number of subreviews per PR. Excess subreviews (sorted
    /// by file count desc) are tail-merged into the unmatched bucket.
    var maxParallelSubreviews: Int

    /// If the splitter (after fanout cap) still produces more than this
    /// many subreviews, collapse them all into one repo-root review. The
    /// PR is too sprawling to split usefully. Nil disables.
    var collapseAboveSubreviewCount: Int?

    // --- Prompt + tools ---

    /// Force a tool mode for this repo (e.g. `.none` for security-sensitive
    /// repos, `.minimal` to enable code exploration). Nil → use the
    /// worker's global default.
    var toolModeOverride: ToolMode?

    /// Optional repo-specific addition (or replacement) for the AI's
    /// system prompt. See `replaceBaseSystemPrompt`.
    var customSystemPrompt: String?

    /// When true, `customSystemPrompt` *replaces* the base system prompt
    /// entirely. Default false: append after the base prompt so the
    /// schema/budget directives still apply.
    var replaceBaseSystemPrompt: Bool = false

    var maxToolCallsPerSubreview: Int
    var maxCostUsdPerSubreview: Double

    // --- Auto-approve ---

    var autoApprove: AutoApproveConfig = .off

    /// Default for any repo not explicitly configured.
    static let `default` = RepoConfig(
        repoGlobs: ["*/*"],
        excluded: false,
        splitMode: .perSubfolder,
        rootPatterns: [],
        unmatchedStrategy: .reviewAtRoot,
        minFilesPerSubreview: 1,
        maxParallelSubreviews: 1,
        collapseAboveSubreviewCount: nil,
        toolModeOverride: nil,
        customSystemPrompt: nil,
        replaceBaseSystemPrompt: false,
        maxToolCallsPerSubreview: 10,
        maxCostUsdPerSubreview: 0.30,
        autoApprove: .off
    )

    /// Bundled default for `getsynq/cloud`. Mirrors the actual top-level
    /// layout: `kernel-*`, `lib/*`, plus the named monorepo apps.
    static let getsynqCloud = RepoConfig(
        repoGlobs: ["getsynq/cloud"],
        excluded: false,
        splitMode: .perSubfolder,
        rootPatterns: [
            "kernel-*", "lib/*",
            "api", "api_public", "app-slack", "fe-app",
            "dev-infra", "dev-tools", "dev-helpers",
            "proto", "proto_public", "playbooks", "Taskfiles",
        ],
        unmatchedStrategy: .reviewAtRoot,
        minFilesPerSubreview: 1,
        maxParallelSubreviews: 4,
        collapseAboveSubreviewCount: 6,
        toolModeOverride: nil,
        customSystemPrompt: nil,
        replaceBaseSystemPrompt: false,
        maxToolCallsPerSubreview: 10,
        maxCostUsdPerSubreview: 0.30,
        autoApprove: .off
    )

    /// Pick the first config whose `repoGlobs` match (negations honored).
    /// Falls back to `.default`.
    static func match(owner: String, repo: String, configs: [RepoConfig] = builtins) -> RepoConfig {
        let nameWithOwner = "\(owner)/\(repo)"
        for config in configs where config.matches(nameWithOwner: nameWithOwner) {
            return config
        }
        return .default
    }

    /// Built-ins ship with PRBar; user overrides land via `RepoConfigStore`.
    static let builtins: [RepoConfig] = [.getsynqCloud]

    func matches(nameWithOwner: String) -> Bool {
        GlobMatcher.anyMatch(repoGlobs, nameWithOwner)
    }
}

/// Back-compat alias. Drop once callers are renamed.
typealias MonorepoConfig = RepoConfig
