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

/// When to fire a "ready for human review" notification for a repo's
/// incoming review requests. Default `.batchSettled` collapses multiple
/// PRs (and their AI triage waits) into one user interruption per cycle.
enum NotifyPolicy: String, Codable, Sendable, Hashable, CaseIterable {
    /// Fire a notification as soon as each PR becomes ready for the user
    /// (current behaviour pre-coordinator). Best for repos where review
    /// latency matters more than batching.
    case eachReady
    /// Hold notifications until every in-flight AI triage settles, then
    /// fire one grouped notification listing every PR ready for review.
    /// Repos with `aiReviewEnabled = false` count as "instantly ready"
    /// and ride the same batch.
    case batchSettled
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
    /// Stable identity. Generated on creation, persisted in the JSON
    /// payload, reused as the UI's row id. Lets the user edit
    /// `repoGlobs` without invalidating selection / orderIndex tracking
    /// — matching by glob string was fragile (rename a glob → row id
    /// changed → selection lost → editor showed the previous draft).
    var id: UUID = UUID()

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

    // --- Filters ---

    /// When false (default), the queue worker skips draft PRs entirely —
    /// no auto-enqueue on review request, no review burned. The user can
    /// still hit Re-run manually from the detail view if they want a
    /// triage of a draft. Flip to true for repos where drafts get real
    /// review activity.
    var reviewDrafts: Bool = false

    /// fnmatch-style globs matched against the PR title (case-insensitive).
    /// Any match → the PR is hidden from the inbox / My PRs lists, isn't
    /// considered for notifications, and the worker never auto-enqueues
    /// it. Manual Re-run from the detail view is unreachable since the
    /// row is hidden — that's intended; if you want to review one of
    /// these, edit the title or unmute the pattern. Examples:
    /// `["[Prod deploy]*", "*chore: bump*"]`.
    var excludeTitlePatterns: [String] = []

    /// When true (default), the worker skips auto-enqueueing PRs that
    /// already have an APPROVED or CHANGES_REQUESTED decision from
    /// another reviewer. PR stays visible in the list — you may still
    /// want to glance at it — just doesn't burn an AI run on something
    /// already covered.
    var skipAIIfReviewedByOthers: Bool = true

    /// Master switch for AI triage on this repo. When false, the queue
    /// worker never auto-enqueues PRs from matching repos and they go
    /// straight to "ready for human" — no waiting on AI. Manual Re-run
    /// from the detail view still bypasses this.
    var aiReviewEnabled: Bool = true

    /// Which `ReviewProvider` runs reviews for this repo. Nil → fall
    /// back to the app-level default (UserDefaults `defaultProviderId`,
    /// itself default `.claude`). PRDetailView's "Re-run with…" menu
    /// can also override this for a single run.
    var providerOverride: ProviderID? = nil

    /// When (and how) to interrupt the user with "ready for review"
    /// notifications. See `NotifyPolicy`. Default batches across the
    /// whole inbox to minimise context switches.
    var notifyPolicy: NotifyPolicy = .batchSettled

    /// Default for any repo not explicitly configured. Computed (not a
    /// `static let`) so each access produces a fresh `id` — otherwise
    /// `var cfg = .default` style cloning at multiple call sites would
    /// have them all collide on the same static UUID.
    static var `default`: RepoConfig { RepoConfig(
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
        maxCostUsdPerSubreview: 1.0,
        autoApprove: .off,
        reviewDrafts: false,
        aiReviewEnabled: true,
        notifyPolicy: .batchSettled
    ) }

    /// Pick the first config whose `repoGlobs` match (negations honored).
    /// Falls back to `.default`. With no built-ins shipped, this only
    /// finds matches in user-supplied configs.
    static func match(owner: String, repo: String, configs: [RepoConfig] = builtins) -> RepoConfig {
        let nameWithOwner = "\(owner)/\(repo)"
        for config in configs where config.matches(nameWithOwner: nameWithOwner) {
            return config
        }
        return .default
    }

    /// No bundled configs — repo-specific layouts belong with their
    /// repos (see PLAN.md: per-repo `.prbar.yml` is the planned source
    /// of truth) or in the user's `RepoConfigStore` overrides.
    static let builtins: [RepoConfig] = []

    func matches(nameWithOwner: String) -> Bool {
        GlobMatcher.anyMatch(repoGlobs, nameWithOwner)
    }

    // MARK: - Codable (forward-compatible)
    //
    // Hand-rolled `init(from:)` so adding new fields to RepoConfig in
    // future never breaks existing JSON payloads stored in the SwiftData
    // `RepoConfigEntry` table — every field decodes via
    // `decodeIfPresent ?? <default from RepoConfig.default>`. The
    // synthesized encoder is fine; only the decoder needs the shim.

    enum CodingKeys: String, CodingKey {
        case id
        case repoGlobs, excluded
        case splitMode, rootPatterns, unmatchedStrategy, minFilesPerSubreview
        case maxParallelSubreviews, collapseAboveSubreviewCount
        case toolModeOverride, customSystemPrompt, replaceBaseSystemPrompt
        case maxToolCallsPerSubreview, maxCostUsdPerSubreview
        case autoApprove
        case reviewDrafts, excludeTitlePatterns, skipAIIfReviewedByOthers
        case aiReviewEnabled, providerOverride, notifyPolicy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RepoConfig.default
        // id was added later. For payloads that predate it we generate
        // a fresh UUID here; the store layer overrides it with the
        // SwiftData row's persistent id so identity stabilizes after
        // the first save.
        self.id                      = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.repoGlobs               = try c.decode([String].self, forKey: .repoGlobs)
        self.excluded                = (try? c.decode(Bool.self, forKey: .excluded)) ?? d.excluded
        self.splitMode               = (try? c.decode(SplitMode.self, forKey: .splitMode)) ?? d.splitMode
        self.rootPatterns            = (try? c.decode([String].self, forKey: .rootPatterns)) ?? d.rootPatterns
        self.unmatchedStrategy       = (try? c.decode(UnmatchedStrategy.self, forKey: .unmatchedStrategy)) ?? d.unmatchedStrategy
        self.minFilesPerSubreview    = (try? c.decode(Int.self, forKey: .minFilesPerSubreview)) ?? d.minFilesPerSubreview
        self.maxParallelSubreviews   = (try? c.decode(Int.self, forKey: .maxParallelSubreviews)) ?? d.maxParallelSubreviews
        self.collapseAboveSubreviewCount = try? c.decodeIfPresent(Int.self, forKey: .collapseAboveSubreviewCount)
        self.toolModeOverride        = try? c.decodeIfPresent(ToolMode.self, forKey: .toolModeOverride)
        self.customSystemPrompt      = try? c.decodeIfPresent(String.self, forKey: .customSystemPrompt)
        self.replaceBaseSystemPrompt = (try? c.decode(Bool.self, forKey: .replaceBaseSystemPrompt)) ?? d.replaceBaseSystemPrompt
        self.maxToolCallsPerSubreview = (try? c.decode(Int.self, forKey: .maxToolCallsPerSubreview)) ?? d.maxToolCallsPerSubreview
        self.maxCostUsdPerSubreview  = (try? c.decode(Double.self, forKey: .maxCostUsdPerSubreview)) ?? d.maxCostUsdPerSubreview
        self.autoApprove             = (try? c.decode(AutoApproveConfig.self, forKey: .autoApprove)) ?? d.autoApprove
        self.reviewDrafts            = (try? c.decode(Bool.self, forKey: .reviewDrafts)) ?? d.reviewDrafts
        self.excludeTitlePatterns    = (try? c.decode([String].self, forKey: .excludeTitlePatterns)) ?? d.excludeTitlePatterns
        self.skipAIIfReviewedByOthers = (try? c.decode(Bool.self, forKey: .skipAIIfReviewedByOthers)) ?? d.skipAIIfReviewedByOthers
        self.aiReviewEnabled         = (try? c.decode(Bool.self, forKey: .aiReviewEnabled)) ?? d.aiReviewEnabled
        self.providerOverride        = try? c.decodeIfPresent(ProviderID.self, forKey: .providerOverride)
        self.notifyPolicy            = (try? c.decode(NotifyPolicy.self, forKey: .notifyPolicy)) ?? d.notifyPolicy
    }

    /// Memberwise init survives the explicit `init(from:)`. Listed so
    /// callers (tests, RepoConfig.default, in-app editors) keep working
    /// — Swift drops the synthesized memberwise init when any explicit
    /// init is added.
    init(
        id: UUID = UUID(),
        repoGlobs: [String],
        excluded: Bool = false,
        splitMode: SplitMode = .perSubfolder,
        rootPatterns: [String] = [],
        unmatchedStrategy: UnmatchedStrategy = .reviewAtRoot,
        minFilesPerSubreview: Int = 1,
        maxParallelSubreviews: Int = 1,
        collapseAboveSubreviewCount: Int? = nil,
        toolModeOverride: ToolMode? = nil,
        customSystemPrompt: String? = nil,
        replaceBaseSystemPrompt: Bool = false,
        maxToolCallsPerSubreview: Int = 10,
        maxCostUsdPerSubreview: Double = 1.0,
        autoApprove: AutoApproveConfig = .off,
        reviewDrafts: Bool = false,
        excludeTitlePatterns: [String] = [],
        skipAIIfReviewedByOthers: Bool = true,
        aiReviewEnabled: Bool = true,
        providerOverride: ProviderID? = nil,
        notifyPolicy: NotifyPolicy = .batchSettled
    ) {
        self.id = id
        self.repoGlobs = repoGlobs
        self.excluded = excluded
        self.splitMode = splitMode
        self.rootPatterns = rootPatterns
        self.unmatchedStrategy = unmatchedStrategy
        self.minFilesPerSubreview = minFilesPerSubreview
        self.maxParallelSubreviews = maxParallelSubreviews
        self.collapseAboveSubreviewCount = collapseAboveSubreviewCount
        self.toolModeOverride = toolModeOverride
        self.customSystemPrompt = customSystemPrompt
        self.replaceBaseSystemPrompt = replaceBaseSystemPrompt
        self.maxToolCallsPerSubreview = maxToolCallsPerSubreview
        self.maxCostUsdPerSubreview = maxCostUsdPerSubreview
        self.autoApprove = autoApprove
        self.reviewDrafts = reviewDrafts
        self.excludeTitlePatterns = excludeTitlePatterns
        self.skipAIIfReviewedByOthers = skipAIIfReviewedByOthers
        self.aiReviewEnabled = aiReviewEnabled
        self.providerOverride = providerOverride
        self.notifyPolicy = notifyPolicy
    }
}

/// Back-compat alias. Drop once callers are renamed.
typealias MonorepoConfig = RepoConfig
