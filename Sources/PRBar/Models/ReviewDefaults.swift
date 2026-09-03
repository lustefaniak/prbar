import Foundation

/// App-level values for every setting a repo rule can override.
///
/// Before this existed, knobs like the per-subreview cost cap lived *only*
/// on `RepoConfig`, so a user with no repo rule ran on compiled-in numbers
/// with no UI showing them — the reported failure mode was a stream of
/// "exceeded budget" errors from a $1.00 cap nobody knew about. Provider,
/// model, effort and merge-confirmation already had an app-default →
/// repo-override chain; this generalises that shape to the rest.
///
/// Edited in Settings → Review defaults, persisted by `RepoConfigStore`.
/// Every field here is non-optional: this *is* the bottom of the lookup
/// chain, so there is nothing left to fall back to.
struct ReviewDefaults: Sendable, Hashable, Codable {
    // MARK: Splitter

    var splitMode: SplitMode = .perSubfolder
    var unmatchedStrategy: UnmatchedStrategy = .reviewAtRoot
    var minFilesPerSubreview: Int = 1
    var maxParallelSubreviews: Int = 1

    /// Collapse to a single repo-root review above this many subreviews.
    /// **0 disables the collapse** — `nil` is not available as "off" here
    /// because on `RepoConfig` `nil` already means "inherit".
    var collapseAboveSubreviewCount: Int = 0

    // MARK: AI

    var toolMode: ToolMode = .sandboxed

    /// Appended to (or, with `replaceBaseSystemPrompt`, substituted for)
    /// the base system prompt on every review. **Empty means none** — the
    /// same reason `collapseAboveSubreviewCount` uses 0.
    var customSystemPrompt: String = ""
    var replaceBaseSystemPrompt: Bool = false
    var aiReviewEnabled: Bool = true
    var forceFullReview: Bool = false

    // MARK: Budgets

    var maxToolCallsPerSubreview: Int = 10

    /// Hard cost ceiling per subreview; the provider SIGTERMs the child
    /// once the stream reports more than this. **0 = uncapped**, with the
    /// daily cap in Settings → General as the remaining backstop.
    ///
    /// $3.00 rather than the original $1.00: a dollar is not enough for a
    /// large PR or a high-effort model, and the failure it produces reads
    /// like a malfunction rather than a budget decision.
    var maxCostUsdPerSubreview: Double = 3.0

    var reviewTimeoutSeconds: Int = 600

    // MARK: Risk brief

    var riskBriefEnabled: Bool = true
    var churnWindowDays: Int = 90
    var churnHistoryDepth: Int = 1_000

    // MARK: Filters

    var reviewDrafts: Bool = false
    var skipAIIfReviewedByOthers: Bool = true

    /// Title globs muted across every repo. A repo rule's own list is
    /// **added** to this one rather than replacing it; to exempt a repo
    /// from a global pattern, negate it there (`!chore: bump *`).
    var excludeTitlePatterns: [String] = []

    // MARK: Notifications

    var notifyPolicy: NotifyPolicy = .batchSettled

    // MARK: Auto-review

    /// Ships `.off`. A repo with no rule of its own inherits these, so an
    /// armed default would let PRBar approve on repos the user never
    /// considered — turning it on here is deliberately an explicit act.
    var autoApprove: AutoApproveConfig = .off
    var autoDeny: AutoDenyConfig = .off

    /// Also ships off. Sharing posts nothing a human vouched for, so like
    /// the two gates above it stays an explicit act — but unlike them it
    /// never casts a verdict, which is what makes it the safe one to turn
    /// on broadly.
    var shareFindings: ShareFindingsPolicy = .off

    /// Confidence floor for a share. Deliberately far below the 0.85 the
    /// two gates use: sharing exists *for* the reviews that miss the
    /// auto-approve floor, so reusing that number would switch the feature
    /// off. 0.5 draws the line at "the model is more confident than not" —
    /// enough to keep a run the model itself barely believes from landing
    /// on the author's PR, without gating the case the feature is for.
    var shareMinConfidence: Double = 0.5

    /// Cap on inline comments one share posts. 0 = unlimited. Neither the
    /// severity floor nor any diff-size cap bounds this: a large PR that
    /// legitimately earns 200 findings would post 200 inline comments in a
    /// single review, which reads as a bot flooding the PR no matter how
    /// good each individual comment is. The summary still carries the rest.
    var shareMaxComments: Int = 20

    /// Whether PRBar may close the review threads it opened once a later
    /// triage stops reporting the finding. Ships off — see
    /// `ResolveThreadsConfig`.
    var resolveThreads: ResolveThreadsConfig = .off

    static let storageKey = "reviewDefaults"

    init() {}

    // MARK: - Codable (forward-compatible)

    enum CodingKeys: String, CodingKey {
        case splitMode, unmatchedStrategy, minFilesPerSubreview
        case maxParallelSubreviews, collapseAboveSubreviewCount
        case toolMode, customSystemPrompt, replaceBaseSystemPrompt
        case aiReviewEnabled, forceFullReview
        case maxToolCallsPerSubreview, maxCostUsdPerSubreview, reviewTimeoutSeconds
        case riskBriefEnabled, churnWindowDays, churnHistoryDepth
        case reviewDrafts, skipAIIfReviewedByOthers, excludeTitlePatterns
        case notifyPolicy
        case autoApprove, autoDeny, shareFindings
        case shareMinConfidence, shareMaxComments, resolveThreads
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ReviewDefaults()
        self.splitMode = (try? c.decode(SplitMode.self, forKey: .splitMode)) ?? d.splitMode
        self.unmatchedStrategy = (try? c.decode(UnmatchedStrategy.self, forKey: .unmatchedStrategy)) ?? d.unmatchedStrategy
        self.minFilesPerSubreview = (try? c.decode(Int.self, forKey: .minFilesPerSubreview)) ?? d.minFilesPerSubreview
        self.maxParallelSubreviews = (try? c.decode(Int.self, forKey: .maxParallelSubreviews)) ?? d.maxParallelSubreviews
        self.collapseAboveSubreviewCount = (try? c.decode(Int.self, forKey: .collapseAboveSubreviewCount)) ?? d.collapseAboveSubreviewCount
        self.toolMode = (try? c.decode(ToolMode.self, forKey: .toolMode)) ?? d.toolMode
        self.customSystemPrompt = (try? c.decode(String.self, forKey: .customSystemPrompt)) ?? d.customSystemPrompt
        self.replaceBaseSystemPrompt = (try? c.decode(Bool.self, forKey: .replaceBaseSystemPrompt)) ?? d.replaceBaseSystemPrompt
        self.aiReviewEnabled = (try? c.decode(Bool.self, forKey: .aiReviewEnabled)) ?? d.aiReviewEnabled
        self.forceFullReview = (try? c.decode(Bool.self, forKey: .forceFullReview)) ?? d.forceFullReview
        self.maxToolCallsPerSubreview = (try? c.decode(Int.self, forKey: .maxToolCallsPerSubreview)) ?? d.maxToolCallsPerSubreview
        self.maxCostUsdPerSubreview = (try? c.decode(Double.self, forKey: .maxCostUsdPerSubreview)) ?? d.maxCostUsdPerSubreview
        self.reviewTimeoutSeconds = (try? c.decode(Int.self, forKey: .reviewTimeoutSeconds)) ?? d.reviewTimeoutSeconds
        self.riskBriefEnabled = (try? c.decode(Bool.self, forKey: .riskBriefEnabled)) ?? d.riskBriefEnabled
        self.churnWindowDays = (try? c.decode(Int.self, forKey: .churnWindowDays)) ?? d.churnWindowDays
        self.churnHistoryDepth = (try? c.decode(Int.self, forKey: .churnHistoryDepth)) ?? d.churnHistoryDepth
        self.reviewDrafts = (try? c.decode(Bool.self, forKey: .reviewDrafts)) ?? d.reviewDrafts
        self.skipAIIfReviewedByOthers = (try? c.decode(Bool.self, forKey: .skipAIIfReviewedByOthers)) ?? d.skipAIIfReviewedByOthers
        self.excludeTitlePatterns = (try? c.decode([String].self, forKey: .excludeTitlePatterns)) ?? d.excludeTitlePatterns
        self.notifyPolicy = (try? c.decode(NotifyPolicy.self, forKey: .notifyPolicy)) ?? d.notifyPolicy
        self.autoApprove = (try? c.decode(AutoApproveConfig.self, forKey: .autoApprove)) ?? d.autoApprove
        self.autoDeny = (try? c.decode(AutoDenyConfig.self, forKey: .autoDeny)) ?? d.autoDeny
        self.shareFindings = (try? c.decode(ShareFindingsPolicy.self, forKey: .shareFindings)) ?? d.shareFindings
        self.shareMinConfidence = (try? c.decode(Double.self, forKey: .shareMinConfidence)) ?? d.shareMinConfidence
        self.shareMaxComments = (try? c.decode(Int.self, forKey: .shareMaxComments)) ?? d.shareMaxComments
        self.resolveThreads = (try? c.decode(ResolveThreadsConfig.self, forKey: .resolveThreads)) ?? d.resolveThreads
    }
}

/// A repo rule with the app defaults folded in — what every consumer of
/// review configuration actually reads.
///
/// Deliberately a façade over `(rule, defaults)` rather than a third flat
/// struct: fields that aren't inheritable (`repoGlobs`, `rootPatterns`,
/// `excluded`) forward straight through with no copy to keep in sync, and
/// adding an inheritable setting means touching `ReviewDefaults` plus one
/// accessor here instead of three declarations.
///
/// Produced only by `RepoConfigStore.resolve(owner:repo:)` /
/// `.makeResolver()` — resolving anywhere else risks reading a rule's raw
/// `nil` as a value rather than as "inherit".
struct ResolvedRepoConfig: Sendable, Hashable {
    let rule: RepoConfig
    let defaults: ReviewDefaults

    init(rule: RepoConfig, defaults: ReviewDefaults) {
        self.rule = rule
        self.defaults = defaults
    }

    // MARK: Per-repo only

    var id: UUID { rule.id }
    var repoGlobs: [String] { rule.repoGlobs }
    var excluded: Bool { rule.excluded }
    var rootPatterns: [String] { rule.rootPatterns }

    // MARK: Already app-level elsewhere (worker-resolved)

    var providerOverride: ProviderID? { rule.providerOverride }
    var claudeModelOverride: String? { rule.claudeModelOverride }
    var claudeEffortOverride: String? { rule.claudeEffortOverride }
    var codexModelOverride: String? { rule.codexModelOverride }
    var codexEffortOverride: String? { rule.codexEffortOverride }
    var skipMergeConfirmation: Bool? { rule.skipMergeConfirmation }

    // MARK: Inheritable

    var splitMode: SplitMode { rule.splitMode ?? defaults.splitMode }
    var unmatchedStrategy: UnmatchedStrategy { rule.unmatchedStrategy ?? defaults.unmatchedStrategy }
    var minFilesPerSubreview: Int { rule.minFilesPerSubreview ?? defaults.minFilesPerSubreview }
    var maxParallelSubreviews: Int { rule.maxParallelSubreviews ?? defaults.maxParallelSubreviews }

    /// Nil when collapsing is off, so call sites keep reading it as an
    /// optional and the 0 sentinel stays contained to storage.
    var collapseAboveSubreviewCount: Int? {
        let value = rule.collapseAboveSubreviewCount ?? defaults.collapseAboveSubreviewCount
        return value > 0 ? value : nil
    }

    var toolMode: ToolMode { rule.toolModeOverride ?? defaults.toolMode }

    /// Nil when there is no custom prompt, for the same reason.
    var customSystemPrompt: String? {
        let value = rule.customSystemPrompt ?? defaults.customSystemPrompt
        return value.isEmpty ? nil : value
    }

    var replaceBaseSystemPrompt: Bool { rule.replaceBaseSystemPrompt ?? defaults.replaceBaseSystemPrompt }
    var aiReviewEnabled: Bool { rule.aiReviewEnabled ?? defaults.aiReviewEnabled }
    var forceFullReview: Bool { rule.forceFullReview ?? defaults.forceFullReview }

    var maxToolCallsPerSubreview: Int { rule.maxToolCallsPerSubreview ?? defaults.maxToolCallsPerSubreview }
    var maxCostUsdPerSubreview: Double { rule.maxCostUsdPerSubreview ?? defaults.maxCostUsdPerSubreview }
    var reviewTimeoutSeconds: Int { rule.reviewTimeoutSeconds ?? defaults.reviewTimeoutSeconds }

    var riskBriefEnabled: Bool { rule.riskBriefEnabled ?? defaults.riskBriefEnabled }
    var churnWindowDays: Int { rule.churnWindowDays ?? defaults.churnWindowDays }
    var churnHistoryDepth: Int { rule.churnHistoryDepth ?? defaults.churnHistoryDepth }

    var reviewDrafts: Bool { rule.reviewDrafts ?? defaults.reviewDrafts }
    var skipAIIfReviewedByOthers: Bool { rule.skipAIIfReviewedByOthers ?? defaults.skipAIIfReviewedByOthers }

    /// Union, not override — the global list is where universally noisy
    /// titles live, and a repo rule adds to it.
    var excludeTitlePatterns: [String] {
        defaults.excludeTitlePatterns + (rule.excludeTitlePatterns ?? [])
    }

    var notifyPolicy: NotifyPolicy { rule.notifyPolicy ?? defaults.notifyPolicy }

    var autoApprove: AutoApproveConfig { rule.autoApprove ?? defaults.autoApprove }
    var autoDeny: AutoDenyConfig { rule.autoDeny ?? defaults.autoDeny }
    var shareFindings: ShareFindingsPolicy { rule.shareFindings ?? defaults.shareFindings }
    var shareMinConfidence: Double { rule.shareMinConfidence ?? defaults.shareMinConfidence }
    var shareMaxComments: Int { rule.shareMaxComments ?? defaults.shareMaxComments }
    var resolveThreads: ResolveThreadsConfig { rule.resolveThreads ?? defaults.resolveThreads }

    func matches(nameWithOwner: String) -> Bool { rule.matches(nameWithOwner: nameWithOwner) }
}

extension RepoConfig {
    /// Fold app defaults into this rule. Tests and previews can call it
    /// with the shipped defaults; production goes through `RepoConfigStore`.
    func resolved(with defaults: ReviewDefaults = ReviewDefaults()) -> ResolvedRepoConfig {
        ResolvedRepoConfig(rule: self, defaults: defaults)
    }
}
