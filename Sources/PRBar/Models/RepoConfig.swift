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
    var enabled: Bool = false

    /// Aggregated confidence floor (0 to 1), used for any provider that
    /// has no dedicated floor below.
    var minConfidence: Double = 0.85

    /// Provider-specific confidence floors. Nil → fall back to
    /// `minConfidence`. Claude and codex don't calibrate their confidence
    /// the same way, so one shared number over-trusts whichever is looser.
    var claudeMinConfidence: Double? = nil
    var codexMinConfidence: Double? = nil

    /// Whether the `.comment` verdict ("Approve with notes") is eligible
    /// too. Off by default: an approval carrying notes usually wants a
    /// human to decide whether the notes matter.
    var allowApproveWithNotes: Bool = false

    /// Highest annotation severity tolerated on an auto-approved review.
    /// `.suggestion` reproduces the old "require zero blocking
    /// annotations" behaviour; `.blocker` tolerates anything.
    var maxAnnotationSeverity: AnnotationSeverity = .suggestion

    /// Cap on total annotation count regardless of severity — a review
    /// with 30 nitpicks is worth reading even when none of them block.
    /// 0 = unlimited.
    var maxAnnotations: Int = 0

    /// Diff-size caps. 0 = unlimited on each.
    var maxAdditions: Int = 200
    var maxDeletions: Int = 0
    var maxChangedFiles: Int = 0

    /// Post "Auto-approved by PRBar (N% confidence)." as the review body.
    /// Off by default — the approval itself is the signal, and the comment
    /// is noise on every PR the bot touches.
    var postAttributionComment: Bool = false

    /// Attach the AI's annotations as inline review comments on the
    /// auto-approved review. Off by default for the same reason.
    var postInlineAnnotations: Bool = false

    /// Confidence floor that applies to a review produced by `provider`.
    func confidenceFloor(for provider: ProviderID) -> Double {
        switch provider {
        case .claude: return claudeMinConfidence ?? minConfidence
        case .codex:  return codexMinConfidence ?? minConfidence
        }
    }

    static let off = AutoApproveConfig()

    // MARK: - Codable (forward-compatible)

    enum CodingKeys: String, CodingKey {
        case enabled, minConfidence
        case claudeMinConfidence, codexMinConfidence
        case allowApproveWithNotes
        case maxAnnotationSeverity, maxAnnotations
        case maxAdditions, maxDeletions, maxChangedFiles
        case postAttributionComment, postInlineAnnotations
        /// Pre-`maxAnnotationSeverity` boolean gate. Decode-only.
        case requireZeroBlockingAnnotations
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AutoApproveConfig()
        self.enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? d.enabled
        self.minConfidence = (try? c.decode(Double.self, forKey: .minConfidence)) ?? d.minConfidence
        self.claudeMinConfidence = try? c.decodeIfPresent(Double.self, forKey: .claudeMinConfidence)
        self.codexMinConfidence = try? c.decodeIfPresent(Double.self, forKey: .codexMinConfidence)
        self.allowApproveWithNotes = (try? c.decode(Bool.self, forKey: .allowApproveWithNotes)) ?? d.allowApproveWithNotes
        // Migration: payloads written before the severity threshold carry
        // the boolean. true → tolerate at most `.suggestion` (the old
        // meaning of "no blocking annotations"); false → tolerate all.
        if let severity = try? c.decodeIfPresent(AnnotationSeverity.self, forKey: .maxAnnotationSeverity) {
            self.maxAnnotationSeverity = severity
        } else if let legacy = try? c.decodeIfPresent(Bool.self, forKey: .requireZeroBlockingAnnotations) {
            self.maxAnnotationSeverity = legacy ? .suggestion : .blocker
        } else {
            self.maxAnnotationSeverity = d.maxAnnotationSeverity
        }
        self.maxAnnotations = (try? c.decode(Int.self, forKey: .maxAnnotations)) ?? d.maxAnnotations
        self.maxAdditions = (try? c.decode(Int.self, forKey: .maxAdditions)) ?? d.maxAdditions
        self.maxDeletions = (try? c.decode(Int.self, forKey: .maxDeletions)) ?? d.maxDeletions
        self.maxChangedFiles = (try? c.decode(Int.self, forKey: .maxChangedFiles)) ?? d.maxChangedFiles
        self.postAttributionComment = (try? c.decode(Bool.self, forKey: .postAttributionComment)) ?? d.postAttributionComment
        self.postInlineAnnotations = (try? c.decode(Bool.self, forKey: .postInlineAnnotations)) ?? d.postInlineAnnotations
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(minConfidence, forKey: .minConfidence)
        try c.encodeIfPresent(claudeMinConfidence, forKey: .claudeMinConfidence)
        try c.encodeIfPresent(codexMinConfidence, forKey: .codexMinConfidence)
        try c.encode(allowApproveWithNotes, forKey: .allowApproveWithNotes)
        try c.encode(maxAnnotationSeverity, forKey: .maxAnnotationSeverity)
        try c.encode(maxAnnotations, forKey: .maxAnnotations)
        try c.encode(maxAdditions, forKey: .maxAdditions)
        try c.encode(maxDeletions, forKey: .maxDeletions)
        try c.encode(maxChangedFiles, forKey: .maxChangedFiles)
        try c.encode(postAttributionComment, forKey: .postAttributionComment)
        try c.encode(postInlineAnnotations, forKey: .postInlineAnnotations)
    }

    /// Restored explicitly — Swift drops the synthesized memberwise init
    /// once `init(from:)` exists.
    init(
        enabled: Bool = false,
        minConfidence: Double = 0.85,
        claudeMinConfidence: Double? = nil,
        codexMinConfidence: Double? = nil,
        allowApproveWithNotes: Bool = false,
        maxAnnotationSeverity: AnnotationSeverity = .suggestion,
        maxAnnotations: Int = 0,
        maxAdditions: Int = 200,
        maxDeletions: Int = 0,
        maxChangedFiles: Int = 0,
        postAttributionComment: Bool = false,
        postInlineAnnotations: Bool = false
    ) {
        self.enabled = enabled
        self.minConfidence = minConfidence
        self.claudeMinConfidence = claudeMinConfidence
        self.codexMinConfidence = codexMinConfidence
        self.allowApproveWithNotes = allowApproveWithNotes
        self.maxAnnotationSeverity = maxAnnotationSeverity
        self.maxAnnotations = maxAnnotations
        self.maxAdditions = maxAdditions
        self.maxDeletions = maxDeletions
        self.maxChangedFiles = maxChangedFiles
        self.postAttributionComment = postAttributionComment
        self.postInlineAnnotations = postInlineAnnotations
    }
}

/// What the auto-deny side does when a negative AI verdict clears its
/// gates. Deliberately separate from a bool: posting `REQUEST_CHANGES` on
/// a colleague's PR on the AI's say-so is a much heavier act than
/// approving, and some repos want the signal without the public verdict.
enum AutoDenyAction: String, Codable, Sendable, Hashable, CaseIterable {
    /// No auto-deny at all (default).
    case off
    /// Mark the PR in PRBar only. Nothing is posted to GitHub; the user
    /// gets a banner and the pre-filled review draft in the detail view.
    case flagOnly = "flag_only"
    /// Post a neutral GitHub COMMENT review with the AI summary. Surfaces
    /// the concerns without blocking the merge.
    case comment
    /// Post a blocking GitHub REQUEST_CHANGES review with the AI summary.
    case requestChanges = "request_changes"

    var displayName: String {
        switch self {
        case .off:            return "Off"
        case .flagOnly:       return "Flag in PRBar only"
        case .comment:        return "Post comment review"
        case .requestChanges: return "Post request changes"
        }
    }

    /// The GitHub review action this posts, or nil when nothing is posted.
    var reviewActionKind: ReviewActionKind? {
        switch self {
        case .off, .flagOnly: return nil
        case .comment:        return .comment
        case .requestChanges: return .requestChanges
        }
    }
}

/// What PRBar sends the PR author when a completed review clears neither
/// the auto-approve nor the auto-deny gates — the common case, since both
/// ship off.
///
/// Without this the findings sit in PRBar until the user gets around to
/// the PR, and the author waits on a review that already exists. Sharing
/// posts a verdict-less GitHub COMMENT review (never APPROVE or
/// REQUEST_CHANGES), so the human reviewer's own verdict is still the one
/// that decides the PR — the author just gets to start on the findings.
///
/// The case is the severity floor, not a separate knob: "off" and "how
/// much is worth sending" are the same decision, and a floor of `.info`
/// with an on/off bool beside it has two ways to spell the same thing.
enum ShareFindingsPolicy: String, Codable, Sendable, Hashable, CaseIterable {
    /// Never post; findings stay in PRBar (default).
    case off
    /// Share when the review found a warning or a blocker.
    case warningsAndBlockers = "warnings_and_blockers"
    /// Share whenever the review produced any annotation at all,
    /// nitpicks included.
    case allFindings = "all_findings"

    var displayName: String {
        switch self {
        case .off:                 return "Off"
        case .warningsAndBlockers: return "Warnings and blockers"
        case .allFindings:         return "Any finding"
        }
    }

    /// Lowest annotation severity that triggers a share, or nil when the
    /// policy is off.
    var minSeverity: AnnotationSeverity? {
        switch self {
        case .off:                 return nil
        case .warningsAndBlockers: return .warning
        case .allFindings:         return .info
        }
    }
}

/// Per-repo auto-deny policy — the mirror of `AutoApproveConfig` for
/// negative verdicts. Gates are separate on purpose: the confidence you
/// need before letting a bot approve is rarely the confidence you need
/// before letting it push back.
struct AutoDenyConfig: Sendable, Hashable, Codable {
    var action: AutoDenyAction = .off

    /// Aggregated confidence floor, used for any provider with no
    /// dedicated floor below.
    var minConfidence: Double = 0.85
    var claudeMinConfidence: Double? = nil
    var codexMinConfidence: Double? = nil

    /// Severity an annotation must reach to count as corroborating the
    /// negative verdict.
    var requiredSeverity: AnnotationSeverity = .warning

    /// How many annotations at or above `requiredSeverity` the review
    /// needs before auto-deny fires. 0 = the verdict alone is enough —
    /// use with care, a summary-only rejection is hard for the author to
    /// action.
    var minMatchingAnnotations: Int = 1

    /// Skip auto-deny above this diff size — a sprawling PR's pushback
    /// reads better authored by a human. 0 = unlimited.
    var maxAdditions: Int = 0

    /// Attach the AI's annotations as inline review comments. On by
    /// default: a "changes requested" without line-level detail is the
    /// least actionable review there is.
    var postInlineAnnotations: Bool = true

    func confidenceFloor(for provider: ProviderID) -> Double {
        switch provider {
        case .claude: return claudeMinConfidence ?? minConfidence
        case .codex:  return codexMinConfidence ?? minConfidence
        }
    }

    static let off = AutoDenyConfig()

    // MARK: - Codable (forward-compatible)

    enum CodingKeys: String, CodingKey {
        case action, minConfidence
        case claudeMinConfidence, codexMinConfidence
        case requiredSeverity, minMatchingAnnotations
        case maxAdditions, postInlineAnnotations
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AutoDenyConfig()
        self.action = (try? c.decode(AutoDenyAction.self, forKey: .action)) ?? d.action
        self.minConfidence = (try? c.decode(Double.self, forKey: .minConfidence)) ?? d.minConfidence
        self.claudeMinConfidence = try? c.decodeIfPresent(Double.self, forKey: .claudeMinConfidence)
        self.codexMinConfidence = try? c.decodeIfPresent(Double.self, forKey: .codexMinConfidence)
        self.requiredSeverity = (try? c.decode(AnnotationSeverity.self, forKey: .requiredSeverity)) ?? d.requiredSeverity
        self.minMatchingAnnotations = (try? c.decode(Int.self, forKey: .minMatchingAnnotations)) ?? d.minMatchingAnnotations
        self.maxAdditions = (try? c.decode(Int.self, forKey: .maxAdditions)) ?? d.maxAdditions
        self.postInlineAnnotations = (try? c.decode(Bool.self, forKey: .postInlineAnnotations)) ?? d.postInlineAnnotations
    }

    init(
        action: AutoDenyAction = .off,
        minConfidence: Double = 0.85,
        claudeMinConfidence: Double? = nil,
        codexMinConfidence: Double? = nil,
        requiredSeverity: AnnotationSeverity = .warning,
        minMatchingAnnotations: Int = 1,
        maxAdditions: Int = 0,
        postInlineAnnotations: Bool = true
    ) {
        self.action = action
        self.minConfidence = minConfidence
        self.claudeMinConfidence = claudeMinConfidence
        self.codexMinConfidence = codexMinConfidence
        self.requiredSeverity = requiredSeverity
        self.minMatchingAnnotations = minMatchingAnnotations
        self.maxAdditions = maxAdditions
        self.postInlineAnnotations = postInlineAnnotations
    }
}

/// Per-repo configuration: monorepo splitter shape, prompt overrides,
/// tool-mode override, auto-approve policy, exclusion. One config per
/// `repoGlobs` entry; the most-specific match wins (built-ins as
/// fallback). Persisted as JSON via `RepoConfigStore`.
///
/// **This is a rule, not an effective configuration.** Every optional
/// field below is an *override*: `nil` means "inherit whatever Settings →
/// Review defaults says". Read them through
/// `RepoConfigStore.resolve(owner:repo:)`, which returns a
/// `ResolvedRepoConfig` with the defaults folded in — reading a raw `nil`
/// here as a value is the mistake this split exists to prevent.
///
/// Two fields needed a second sentinel because `nil` was already taken:
/// `collapseAboveSubreviewCount` uses `0` for "off" and
/// `customSystemPrompt` uses `""` for "none".
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

    var splitMode: SplitMode?

    /// Ordered list of fnmatch-style root patterns. Longest literal prefix
    /// wins on ties. Ignored when `splitMode == .single`. Per-repo only —
    /// a directory layout has no meaningful app-wide default.
    var rootPatterns: [String]

    var unmatchedStrategy: UnmatchedStrategy?

    /// Subreviews with fewer files than this fold into the unmatched
    /// bucket per `unmatchedStrategy`.
    var minFilesPerSubreview: Int?

    /// Cap on the number of subreviews per PR. Excess subreviews (sorted
    /// by file count desc) are tail-merged into the unmatched bucket.
    var maxParallelSubreviews: Int?

    /// If the splitter (after fanout cap) still produces more than this
    /// many subreviews, collapse them all into one repo-root review. The
    /// PR is too sprawling to split usefully. **0 disables** — `nil` means
    /// inherit.
    var collapseAboveSubreviewCount: Int?

    // --- Prompt + tools ---

    /// Force a tool mode for this repo (e.g. `.none` for security-sensitive
    /// repos, `.minimal` to enable code exploration).
    var toolModeOverride: ToolMode?

    /// Repo-specific addition to (or replacement for) the AI's system
    /// prompt. See `replaceBaseSystemPrompt`. **`""` means none** — `nil`
    /// means inherit.
    var customSystemPrompt: String?

    /// When true, `customSystemPrompt` *replaces* the base system prompt
    /// entirely. False appends after the base prompt so the schema/budget
    /// directives still apply.
    var replaceBaseSystemPrompt: Bool?

    var maxToolCallsPerSubreview: Int?

    /// **0 = uncapped** (the daily cap still applies); `nil` = inherit.
    var maxCostUsdPerSubreview: Double?

    // --- Risk brief ---

    /// Prepend a mechanical "where to look first" ranking of the changed
    /// files to each subreview's prompt. See `RiskBrief` — it routes the
    /// judge's attention on large diffs and never contributes to the
    /// verdict. Cheap (pure computation plus one `git log`), so on by
    /// default; turn off for a repo where the ranking misleads more than
    /// it helps.
    var riskBriefEnabled: Bool?

    /// Trailing window for the risk brief's commit-churn term, in days.
    /// 0 disables churn and leaves the rest of the brief intact. The
    /// bare clone is shallow (`--depth=50`), so on a busy repo the
    /// observed window is much shorter than this — `RiskBrief` drops the
    /// term entirely when too little history is present rather than rank
    /// on noise.
    var churnWindowDays: Int?

    /// Commit depth fetched into the bare clone when the churn term is on.
    ///
    /// Cheap because the clone is `--filter=blob:none`: deepening carries
    /// commits and trees but never blobs, so file size (binaries, vendored
    /// assets) does not enter into it. Measured on a ~160 MB blobless
    /// monorepo clone, 10 → 1000 commits cost 6.9 s and 1.8 MiB of pack,
    /// once per repo.
    ///
    /// **Depth, not `churnWindowDays`, is the binding constraint.** On a busy
    /// monorepo 1000 commits spanned 17–21 days in practice, so a 90-day
    /// `churnWindowDays` really yields ~3 weeks — enough for "hot right now",
    /// short of "chronically hot". `RiskBrief` reports the observed span in
    /// the prompt so the window is never oversold. Raise this (roughly
    /// linearly) if you want the full window; 4000 ≈ 3 months there.
    var churnHistoryDepth: Int?

    /// Hard wall-clock ceiling per subreview, in seconds. The provider
    /// SIGTERMs (then SIGKILLs) the `claude`/`codex` child past this.
    /// Generous by default: `.sandboxed` reviews explore a worktree over
    /// multiple turns and legitimately run minutes on a large PR — a tight
    /// ceiling kills the run mid-flight (surfaces as `exited 143`).
    var reviewTimeoutSeconds: Int?

    // --- Auto-review ---

    /// Inherits as a whole struct: a rule either defines its own
    /// auto-approve policy or takes the app-level one. There is no
    /// field-level merge inside it — half-inherited gates would be very
    /// hard to reason about for something that posts to GitHub.
    var autoApprove: AutoApproveConfig?

    /// Negative-verdict counterpart to `autoApprove`.
    var autoDeny: AutoDenyConfig?

    /// What to send the author when neither auto side fires. See
    /// `ShareFindingsPolicy`.
    var shareFindings: ShareFindingsPolicy?

    // --- Filters ---

    /// When false (default), the queue worker skips draft PRs entirely —
    /// no auto-enqueue on review request, no review burned. The user can
    /// still hit Re-run manually from the detail view if they want a
    /// triage of a draft. Flip to true for repos where drafts get real
    /// review activity.
    var reviewDrafts: Bool?

    /// fnmatch-style globs matched against the PR title (case-insensitive).
    /// **Added to** the app-level list rather than replacing it.
    /// Any match → the PR is hidden from the inbox / My PRs lists, isn't
    /// considered for notifications, and the worker never auto-enqueues
    /// it. Manual Re-run from the detail view is unreachable since the
    /// row is hidden — that's intended; if you want to review one of
    /// these, edit the title or unmute the pattern. Examples:
    /// `["[Prod deploy]*", "*chore: bump*"]`.
    var excludeTitlePatterns: [String]?

    /// When true (default), the worker skips auto-enqueueing PRs that
    /// already have an APPROVED or CHANGES_REQUESTED decision from
    /// another reviewer. PR stays visible in the list — you may still
    /// want to glance at it — just doesn't burn an AI run on something
    /// already covered.
    var skipAIIfReviewedByOthers: Bool?

    /// Master switch for AI triage on this repo. When false, the queue
    /// worker never auto-enqueues PRs from matching repos and they go
    /// straight to "ready for human" — no waiting on AI. Manual Re-run
    /// from the detail view still bypasses this.
    var aiReviewEnabled: Bool?

    /// Which `ReviewProvider` runs reviews for this repo. Nil → fall
    /// back to the app-level default (UserDefaults `defaultProviderId`,
    /// itself default `.claude`). PRDetailView's "Re-run with…" menu
    /// can also override this for a single run.
    var providerOverride: ProviderID? = nil

    /// Per-repo model override for the `claude` CLI's `--model` flag
    /// (e.g. "sonnet", "opus", "haiku", "fable", or a full model id).
    /// Nil → fall back to the app-level default (`ReviewQueueWorker
    /// .defaultClaudeModel`). Only applies when this repo actually runs
    /// on the claude provider.
    var claudeModelOverride: String? = nil

    /// Per-repo reasoning-effort override for claude's `--effort` flag
    /// (low/medium/high/xhigh/max). Nil → app-level default
    /// (`defaultClaudeEffort`); empty app default → no flag passed
    /// (claude's own default effort applies).
    var claudeEffortOverride: String? = nil

    /// Per-repo model override for the `codex` CLI's `--model` flag.
    /// Codex has no stable short aliases the way claude does ("sonnet"
    /// etc.) — pass a literal model id (e.g. "gpt-5.5"). Nil → app-level
    /// default (`defaultCodexModel`).
    var codexModelOverride: String? = nil

    /// Per-repo reasoning-effort override for codex's
    /// `model_reasoning_effort` config key
    /// (none/minimal/low/medium/high/xhigh). Nil → app-level default
    /// (`defaultCodexEffort`).
    var codexEffortOverride: String? = nil

    /// When (and how) to interrupt the user with "ready for review"
    /// notifications. See `NotifyPolicy`. Default batches across the
    /// whole inbox to minimise context switches.
    var notifyPolicy: NotifyPolicy?

    /// Per-repo override for the "confirm before merge" dialog. Nil →
    /// follow the global `skipMergeConfirmation` setting; `true` → always
    /// merge without confirming on this repo; `false` → always confirm.
    var skipMergeConfirmation: Bool? = nil

    /// When true, retriages drop the prior verdict from the prompt and
    /// review the full PR fresh. The default `false` carries the prior
    /// summary forward so the AI can frame its verdict as "did the new
    /// commits address prior concerns?" — saves cost and reduces churn,
    /// but biases the model toward judging only the increment. Flip on
    /// for repos where every retriage should re-evaluate the whole diff.
    var forceFullReview: Bool?

    /// The rule used for any repo without one of its own: matches
    /// everything and overrides nothing, so every setting resolves from
    /// `ReviewDefaults`. Also the shape a freshly-added rule starts in.
    ///
    /// Computed (not a `static let`) so each access produces a fresh `id`
    /// — otherwise `var cfg = .default` style cloning at multiple call
    /// sites would have them all collide on the same static UUID.
    static var `default`: RepoConfig { RepoConfig(repoGlobs: ["*/*"]) }

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
    /// repos (per-repo `.prbar.yml` is the planned source of truth) or
    /// in the user's `RepoConfigStore` overrides.
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
        case maxToolCallsPerSubreview, maxCostUsdPerSubreview, reviewTimeoutSeconds
        case riskBriefEnabled, churnWindowDays, churnHistoryDepth
        case autoApprove, autoDeny, shareFindings
        case reviewDrafts, excludeTitlePatterns, skipAIIfReviewedByOthers
        case aiReviewEnabled, providerOverride, notifyPolicy
        case forceFullReview
        case skipMergeConfirmation
        case claudeModelOverride, claudeEffortOverride
        case codexModelOverride, codexEffortOverride
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // id was added later. For payloads that predate it we generate
        // a fresh UUID here; the store layer overrides it with the
        // SwiftData row's persistent id so identity stabilizes after
        // the first save.
        self.id                      = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.repoGlobs               = try c.decode([String].self, forKey: .repoGlobs)
        self.excluded                = (try? c.decode(Bool.self, forKey: .excluded)) ?? false
        self.rootPatterns            = (try? c.decode([String].self, forKey: .rootPatterns)) ?? []
        // Every field below is an override. A payload written before
        // inheritance existed carries a concrete value for each, which
        // decodes as an explicit override — so a rule a user already
        // configured keeps behaving exactly as it did.
        self.splitMode               = try? c.decodeIfPresent(SplitMode.self, forKey: .splitMode)
        self.unmatchedStrategy       = try? c.decodeIfPresent(UnmatchedStrategy.self, forKey: .unmatchedStrategy)
        self.minFilesPerSubreview    = try? c.decodeIfPresent(Int.self, forKey: .minFilesPerSubreview)
        self.maxParallelSubreviews   = try? c.decodeIfPresent(Int.self, forKey: .maxParallelSubreviews)
        self.collapseAboveSubreviewCount = try? c.decodeIfPresent(Int.self, forKey: .collapseAboveSubreviewCount)
        self.toolModeOverride        = try? c.decodeIfPresent(ToolMode.self, forKey: .toolModeOverride)
        self.customSystemPrompt      = try? c.decodeIfPresent(String.self, forKey: .customSystemPrompt)
        self.replaceBaseSystemPrompt = try? c.decodeIfPresent(Bool.self, forKey: .replaceBaseSystemPrompt)
        self.maxToolCallsPerSubreview = try? c.decodeIfPresent(Int.self, forKey: .maxToolCallsPerSubreview)
        self.maxCostUsdPerSubreview  = try? c.decodeIfPresent(Double.self, forKey: .maxCostUsdPerSubreview)
        self.reviewTimeoutSeconds    = try? c.decodeIfPresent(Int.self, forKey: .reviewTimeoutSeconds)
        self.riskBriefEnabled        = try? c.decodeIfPresent(Bool.self, forKey: .riskBriefEnabled)
        self.churnWindowDays         = try? c.decodeIfPresent(Int.self, forKey: .churnWindowDays)
        self.churnHistoryDepth       = try? c.decodeIfPresent(Int.self, forKey: .churnHistoryDepth)
        self.autoApprove             = try? c.decodeIfPresent(AutoApproveConfig.self, forKey: .autoApprove)
        self.autoDeny                = try? c.decodeIfPresent(AutoDenyConfig.self, forKey: .autoDeny)
        self.shareFindings           = try? c.decodeIfPresent(ShareFindingsPolicy.self, forKey: .shareFindings)
        self.reviewDrafts            = try? c.decodeIfPresent(Bool.self, forKey: .reviewDrafts)
        self.excludeTitlePatterns    = try? c.decodeIfPresent([String].self, forKey: .excludeTitlePatterns)
        self.skipAIIfReviewedByOthers = try? c.decodeIfPresent(Bool.self, forKey: .skipAIIfReviewedByOthers)
        self.aiReviewEnabled         = try? c.decodeIfPresent(Bool.self, forKey: .aiReviewEnabled)
        self.providerOverride        = try? c.decodeIfPresent(ProviderID.self, forKey: .providerOverride)
        self.notifyPolicy            = try? c.decodeIfPresent(NotifyPolicy.self, forKey: .notifyPolicy)
        self.forceFullReview         = try? c.decodeIfPresent(Bool.self, forKey: .forceFullReview)
        self.skipMergeConfirmation   = try? c.decodeIfPresent(Bool.self, forKey: .skipMergeConfirmation)
        self.claudeModelOverride     = try? c.decodeIfPresent(String.self, forKey: .claudeModelOverride)
        self.claudeEffortOverride    = try? c.decodeIfPresent(String.self, forKey: .claudeEffortOverride)
        self.codexModelOverride      = try? c.decodeIfPresent(String.self, forKey: .codexModelOverride)
        self.codexEffortOverride     = try? c.decodeIfPresent(String.self, forKey: .codexEffortOverride)
    }

    /// Memberwise init survives the explicit `init(from:)`. Listed so
    /// callers (tests, RepoConfig.default, in-app editors) keep working
    /// — Swift drops the synthesized memberwise init when any explicit
    /// init is added.
    init(
        id: UUID = UUID(),
        repoGlobs: [String],
        excluded: Bool = false,
        splitMode: SplitMode? = nil,
        rootPatterns: [String] = [],
        unmatchedStrategy: UnmatchedStrategy? = nil,
        minFilesPerSubreview: Int? = nil,
        maxParallelSubreviews: Int? = nil,
        collapseAboveSubreviewCount: Int? = nil,
        toolModeOverride: ToolMode? = nil,
        customSystemPrompt: String? = nil,
        replaceBaseSystemPrompt: Bool? = nil,
        maxToolCallsPerSubreview: Int? = nil,
        maxCostUsdPerSubreview: Double? = nil,
        reviewTimeoutSeconds: Int? = nil,
        riskBriefEnabled: Bool? = nil,
        churnWindowDays: Int? = nil,
        churnHistoryDepth: Int? = nil,
        autoApprove: AutoApproveConfig? = nil,
        autoDeny: AutoDenyConfig? = nil,
        shareFindings: ShareFindingsPolicy? = nil,
        reviewDrafts: Bool? = nil,
        excludeTitlePatterns: [String]? = nil,
        skipAIIfReviewedByOthers: Bool? = nil,
        aiReviewEnabled: Bool? = nil,
        providerOverride: ProviderID? = nil,
        notifyPolicy: NotifyPolicy? = nil,
        forceFullReview: Bool? = nil,
        skipMergeConfirmation: Bool? = nil,
        claudeModelOverride: String? = nil,
        claudeEffortOverride: String? = nil,
        codexModelOverride: String? = nil,
        codexEffortOverride: String? = nil
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
        self.reviewTimeoutSeconds = reviewTimeoutSeconds
        self.riskBriefEnabled = riskBriefEnabled
        self.churnWindowDays = churnWindowDays
        self.churnHistoryDepth = churnHistoryDepth
        self.autoApprove = autoApprove
        self.autoDeny = autoDeny
        self.shareFindings = shareFindings
        self.reviewDrafts = reviewDrafts
        self.excludeTitlePatterns = excludeTitlePatterns
        self.skipAIIfReviewedByOthers = skipAIIfReviewedByOthers
        self.aiReviewEnabled = aiReviewEnabled
        self.providerOverride = providerOverride
        self.notifyPolicy = notifyPolicy
        self.forceFullReview = forceFullReview
        self.skipMergeConfirmation = skipMergeConfirmation
        self.claudeModelOverride = claudeModelOverride
        self.claudeEffortOverride = claudeEffortOverride
        self.codexModelOverride = codexModelOverride
        self.codexEffortOverride = codexEffortOverride
    }
}

/// Back-compat alias. Drop once callers are renamed.
typealias MonorepoConfig = RepoConfig
