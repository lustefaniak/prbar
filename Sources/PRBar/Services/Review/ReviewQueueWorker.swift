import Foundation
import Observation
import OSLog

/// One pending or completed AI review keyed by PR node ID. Drives the
/// per-row "review status" UI in the inbox and the AI section in the
/// detail pane.
struct ReviewState: Sendable, Hashable, Codable {
    /// Why auto-triage deliberately did not review a PR. Recorded as a
    /// terminal status so the UI can explain *why* a review-requested PR
    /// wasn't triaged instead of leaving it on a perpetual "not started".
    enum SkipReason: String, Sendable, Hashable, Codable, CaseIterable {
        /// `aiReviewEnabled == false` for the repo.
        case aiReviewDisabled
        /// PR is a draft and `reviewDrafts == false` for the repo.
        case draftNotReviewed
        /// Another human already reviewed and `skipAIIfReviewedByOthers` is on.
        case reviewedByOthers

        /// Full-sentence explanation for the detail pane.
        var detail: String {
            switch self {
            case .aiReviewDisabled:
                return "AI review is turned off for this repository."
            case .draftNotReviewed:
                return "This PR is a draft, and draft review is off for this repository."
            case .reviewedByOthers:
                return "Another reviewer already weighed in, and \"skip when reviewed by others\" is on for this repository."
            }
        }

        /// Terse phrase for the row badge tooltip.
        var short: String {
            switch self {
            case .aiReviewDisabled: return "AI review off for this repo"
            case .draftNotReviewed: return "draft review off for this repo"
            case .reviewedByOthers: return "already reviewed by others"
            }
        }
    }

    enum Status: Sendable, Hashable, Codable {
        case queued
        case running
        case completed(AggregatedReview)
        case failed(String)
        /// Auto-triage chose not to run for a repo-config reason. Terminal;
        /// a manual Re-run (`force`) bypasses it, and a new head SHA re-arms.
        case skipped(SkipReason)

        var isTerminal: Bool {
            switch self {
            case .queued, .running: return false
            case .completed, .failed, .skipped: return true
            }
        }

        var isInFlight: Bool {
            switch self {
            case .queued, .running: return true
            case .completed, .failed, .skipped: return false
            }
        }
    }

    let prNodeId: String
    /// Which AI backend produced (or is producing) this review. Surfaced
    /// in the UI so the user can tell whether they're looking at a
    /// claude verdict vs a codex verdict.
    var providerId: ProviderID = .claude
    /// Commit SHA the review ran against. Used to detect staleness on
    /// subsequent polls — if the PR's headSha changes, the cached
    /// review is for an older commit and we should re-triage.
    let headSha: String
    let triggeredAt: Date
    var status: Status
    /// Cost spent on this review (sum across subreviews after completion;
    /// 0 while running).
    var costUsd: Double

    /// Chain of completed-but-unposted reviews from earlier commits,
    /// oldest first. Grows when the PR's head moves before the user
    /// posts the verdict; cleared when a new review completes
    /// successfully. The model needs the *whole* chain so it can issue
    /// one consolidated final review for the PR's current state instead
    /// of a delta against a draft the PR author never saw.
    var priorReviews: [PriorReview] = []

    /// Convenience for UI consumers that only need the most recent
    /// snapshot (verdict pill, stale banner).
    var latestPrior: PriorReview? { priorReviews.last }

    enum CodingKeys: String, CodingKey {
        case prNodeId, providerId, headSha, triggeredAt, status, costUsd
        case priorReviews
        case priorReview // legacy singular
    }

    init(
        prNodeId: String,
        providerId: ProviderID = .claude,
        headSha: String,
        triggeredAt: Date,
        status: Status,
        costUsd: Double,
        priorReviews: [PriorReview] = []
    ) {
        self.prNodeId = prNodeId
        self.providerId = providerId
        self.headSha = headSha
        self.triggeredAt = triggeredAt
        self.status = status
        self.costUsd = costUsd
        self.priorReviews = priorReviews
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(prNodeId, forKey: .prNodeId)
        try c.encode(providerId, forKey: .providerId)
        try c.encode(headSha, forKey: .headSha)
        try c.encode(triggeredAt, forKey: .triggeredAt)
        try c.encode(status, forKey: .status)
        try c.encode(costUsd, forKey: .costUsd)
        try c.encode(priorReviews, forKey: .priorReviews)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.prNodeId = try c.decode(String.self, forKey: .prNodeId)
        self.providerId = try c.decodeIfPresent(ProviderID.self, forKey: .providerId) ?? .claude
        self.headSha = try c.decode(String.self, forKey: .headSha)
        self.triggeredAt = try c.decode(Date.self, forKey: .triggeredAt)
        self.status = try c.decode(Status.self, forKey: .status)
        self.costUsd = try c.decodeIfPresent(Double.self, forKey: .costUsd) ?? 0
        if let chain = try c.decodeIfPresent([PriorReview].self, forKey: .priorReviews) {
            self.priorReviews = chain
        } else if let legacy = try c.decodeIfPresent(PriorReview.self, forKey: .priorReview) {
            self.priorReviews = [legacy]
        } else {
            self.priorReviews = []
        }
    }
}

/// Snapshot of a completed AI review for an earlier commit, captured
/// when the worker re-queues a PR after its head moves.
struct PriorReview: Sendable, Hashable, Codable {
    let headSha: String
    let aggregated: AggregatedReview
}

/// Actor (well, @MainActor @Observable class) that drains a queue of
/// pending PR reviews. Auto-enqueues incoming review requests; can be
/// triggered manually for re-runs. Concurrency-bounded.
@MainActor
@Observable
final class ReviewQueueWorker {
    private(set) var reviews: [String: ReviewState] = [:]

    /// Live snapshot from the running provider, keyed by PR node ID.
    /// Cleared when a review reaches a terminal state. Tools used /
    /// cost-so-far / last assistant text — drives the in-progress UI in
    /// `PRDetailView` so the user sees something happening instead of
    /// a bare spinner.
    private(set) var liveProgress: [String: ReviewProgress] = [:]

    /// Hard cap on parallel reviews. Each review is one or more provider
    /// calls (one per Subdiff); 2 concurrent calls = ~$0.40 burst at the
    /// minimal-tools rates.
    var maxConcurrent: Int = 2

    /// Daily spend ceiling. Computed from the total of all completed
    /// reviews today (not a real running daily-window — for now we cap
    /// the cumulative since process start, which is good enough for a
    /// menu-bar app that gets restarted often).
    /// Daily spend ceiling. Honored only when `dailyCostCapEnabled` is
    /// true — subscription-auth users (Claude MAX, codex via OpenAI
    /// subscription) typically want it off since the per-token cost
    /// `claude` reports is informational, not actually billed.
    var dailyCostCap: Double = 5.0
    var dailyCostCapEnabled: Bool = true

    /// Default AI provider. Used when `providerLookup` is nil (mostly in
    /// tests that pass a single stub via `worker.provider = …`).
    /// Production wiring uses `providerLookup` so per-repo / per-run
    /// `ProviderID`s map to the right backend.
    @ObservationIgnored
    var provider: ReviewProvider = ClaudeProvider()

    /// Resolves `ProviderID` → concrete `ReviewProvider`. When set, the
    /// worker uses this instead of `provider` for every run. Production
    /// wires `{ .claude → ClaudeProvider, .codex → CodexProvider }`.
    @ObservationIgnored
    var providerLookup: (@Sendable (ProviderID) -> ReviewProvider)? = { id in
        switch id {
        case .claude: return ClaudeProvider()
        case .codex:  return CodexProvider()
        }
    }

    /// App-level default provider. Per-repo `RepoConfig.providerOverride`
    /// wins over this; per-run override (set on enqueue) wins over both.
    var defaultProviderId: ProviderID = .claude

    /// App-level default `--model` for the claude provider. Defaults to
    /// the "sonnet" alias so a user's own `claude` CLI default (e.g. a
    /// non-default model picked in an interactive session) never leaks
    /// into unattended PRBar reviews and silently burns their quota.
    /// Empty string = no override (claude's own default applies).
    /// `RepoConfig.claudeModelOverride` wins over this.
    var defaultClaudeModel: String = "sonnet"

    /// App-level default `--effort` for the claude provider. Empty =
    /// no flag passed (claude's own default effort applies — there is
    /// no native "auto" value, this is the closest equivalent).
    /// `RepoConfig.claudeEffortOverride` wins over this.
    var defaultClaudeEffort: String = ""

    /// App-level default `--model` for the codex provider. Empty = no
    /// override (codex's own configured default applies). Unlike
    /// claude, codex has no stable short aliases, so there's no safe
    /// non-empty default to hardcode here.
    /// `RepoConfig.codexModelOverride` wins over this.
    var defaultCodexModel: String = ""

    /// App-level default `model_reasoning_effort` for the codex
    /// provider. Empty = no override (codex's own configured default
    /// applies). `RepoConfig.codexEffortOverride` wins over this.
    var defaultCodexEffort: String = ""

    /// Resolve the `--model` to pass for a run: repo override wins over
    /// the app-level default; empty strings (unset fields) mean "no
    /// override" and resolve to nil (no `--model` flag).
    func resolveModel(providerId: ProviderID, config: ResolvedRepoConfig) -> String? {
        switch providerId {
        case .claude: return Self.nonEmpty(config.claudeModelOverride) ?? Self.nonEmpty(defaultClaudeModel)
        case .codex:  return Self.nonEmpty(config.codexModelOverride) ?? Self.nonEmpty(defaultCodexModel)
        }
    }

    /// Resolve the reasoning-effort override to pass for a run. Same
    /// repo-override-wins-over-app-default precedence as `resolveModel`.
    func resolveEffort(providerId: ProviderID, config: ResolvedRepoConfig) -> String? {
        switch providerId {
        case .claude: return Self.nonEmpty(config.claudeEffortOverride) ?? Self.nonEmpty(defaultClaudeEffort)
        case .codex:  return Self.nonEmpty(config.codexEffortOverride) ?? Self.nonEmpty(defaultCodexEffort)
        }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    /// Closure that fetches the unified diff for a PR. Injected so tests
    /// don't need a real `gh` install.
    @ObservationIgnored
    var diffFetcher: @Sendable (_ owner: String, _ repo: String, _ number: Int) async throws -> String

    /// Optional shared `FailureLogStore` — when present the worker
    /// fetches the tail of every failed Actions job and feeds it into
    /// the prompt's `## CI failures` section, plus warms the store
    /// cache so PRDetailView's expandable failure log doesn't refetch.
    /// Tests that don't care about CI logs leave this nil.
    @ObservationIgnored
    var failureLogStore: FailureLogStore?

    /// Resolves the effective config used when reviewing a PR — the
    /// matching repo rule with `ReviewDefaults` folded in. Pluggable so
    /// tests can stub it and runtime can swap the live `RepoConfigStore`.
    /// Default uses the built-in registry and the shipped defaults.
    @ObservationIgnored
    var configResolver: @Sendable (_ owner: String, _ repo: String) -> ResolvedRepoConfig = { owner, repo in
        RepoConfig.match(owner: owner, repo: repo).resolved()
    }

    /// On-disk checkout manager. Used in `.minimal` tool mode to give the
    /// AI a real workdir for `Read`/`Grep`. Nil → fall back to empty temp
    /// dirs (which only makes sense in `.none` mode anyway).
    @ObservationIgnored
    var checkoutManager: RepoCheckoutManager?

    /// Fetches a PR's review threads. Injected so tests don't shell out;
    /// nil disables the resolve-on-triage path entirely.
    @ObservationIgnored
    var reviewThreadFetcher: (@Sendable (_ owner: String, _ repo: String, _ number: Int) async throws -> ReviewThreadPage)?

    /// Hands a batch of resolvable thread ids to `ActionQueue`. Wired in
    /// `AppDelegate`; nil in tests that only assert the decision.
    @ObservationIgnored
    var enqueueResolveThreads: (@MainActor (_ pr: InboxPR, _ threadIds: [String]) -> Void)?

    /// Reads commit history for `RiskBrief`'s churn term. Injected so tests
    /// exercise the brief without a real checkout; returning nil is the
    /// normal degraded path, not an error.
    @ObservationIgnored
    var churnFetcher: @Sendable (_ worktree: URL, _ windowDays: Int) async -> ChurnWindow? = { worktree, days in
        await GitChurn.fetch(worktree: worktree, windowDays: days)
    }

    /// Finds changed files carrying a generated-code marker, for
    /// `RiskBrief`. Injected so tests don't need files on disk.
    @ObservationIgnored
    var generatedScanner: @Sendable (_ paths: [String], _ worktree: URL) async -> Set<String> = { paths, worktree in
        await GeneratedCodeScanner.scan(paths: paths, in: worktree)
    }

    @ObservationIgnored
    private var inFlight: Int = 0

    @ObservationIgnored
    private var pending: [PendingItem] = []

    /// One queued review. Carries an optional per-run provider override
    /// captured at enqueue time so PRDetailView's "Re-run with codex"
    /// can dispatch to a non-default backend just for that run.
    private struct PendingItem {
        let pr: InboxPR
        let providerOverride: ProviderID?
    }

    /// Disk persistence. Loads on init, saves after every state mutation.
    /// Nil disables persistence (used by tests).
    @ObservationIgnored
    var cache: ReviewCache?

    // MARK: - Auto-review batch state
    //
    // Approvals and denials stage here when `AutoReviewPolicy` says yes.
    // The undo banner only appears once *all* enqueued reviews have settled
    // (no .queued / .running). Design goal: one context switch per cycle,
    // not one per PR.

    /// PRs with a staged post (approve / comment / request-changes), keyed
    /// by node ID. Population happens at completion time; presentation is
    /// gated by `batchUndoActive`.
    private(set) var pendingAutoActions: [String: StagedAutoReview] = [:]

    /// PRs whose negative verdict cleared the deny gates under
    /// `AutoDenyAction.flagOnly`. Nothing is ever posted for these — they
    /// exist so the banner can surface "the AI wants changes here" without
    /// PRBar speaking on the user's behalf. In-memory only: the verdict
    /// itself persists in `reviews`, so a relaunch loses the nudge, not the
    /// finding.
    private(set) var flaggedDenials: [String: StagedAutoReview] = [:]

    /// True when a batch undo banner is currently counting down (visible
    /// in `PopoverView`). Set by `scheduleBatchIfSettled()`, cleared on
    /// undo / fire.
    private(set) var batchUndoActive: Bool = false

    /// Wall-clock deadline at which the batch fires. Nil unless the
    /// banner is showing.
    private(set) var batchUndoDeadline: Date? = nil

    /// How long the user has to undo the staged batch. 30 s per PLAN.
    var undoWindow: TimeInterval = 30

    /// Closure that posts a staged auto-review. Injected so tests don't
    /// shell out. Only used by the fallback path when `enqueueAutoReview`
    /// is nil (i.e. in tests); production routes through `ActionQueue`.
    @ObservationIgnored
    var autoReviewPoster: @Sendable (
        _ pr: InboxPR, _ kind: ReviewActionKind, _ body: String,
        _ comments: [GHClient.InlineComment]
    ) async throws -> Void = { pr, kind, body, comments in
        let c = try GHClient()
        if comments.isEmpty {
            try await c.postReview(
                owner: pr.owner, repo: pr.repo, number: pr.number,
                kind: kind, body: body
            )
        } else {
            try await c.postReviewWithComments(
                owner: pr.owner, repo: pr.repo, number: pr.number,
                event: kind.apiEvent, body: body, comments: comments
            )
        }
    }

    /// When set, `fireBatch` hands each staged post to the shared
    /// `ActionQueue` instead of posting it inline — so auto-review shares
    /// the same serialization, dedup, retry, and action-log path as manual
    /// writes. Nil keeps the legacy `autoReviewPoster` path (tests). Wired
    /// by `AppDelegate`.
    @ObservationIgnored
    var enqueueAutoReview: (@MainActor (
        _ pr: InboxPR, _ kind: ReviewActionKind, _ body: String,
        _ comments: [GHClient.InlineComment], _ costUsd: Double,
        _ source: ActionSource
    ) -> Void)?

    @ObservationIgnored
    private var batchTimer: Task<Void, Never>?

    /// Fired every time a review reaches a terminal state (`.completed`
    /// / `.failed`). The `ReadinessCoordinator` listens here to flip its
    /// "AI-pending" → "ready for human" bit per PR. `isWorkerSettled` is
    /// true when no review is still queued or running after this one.
    @ObservationIgnored
    var onReviewSettled: (@MainActor (_ prNodeId: String, _ isWorkerSettled: Bool) -> Void)?

    /// Action history sink. When set, `fireBatch()` records one entry
    /// per auto-approved PR so the History tab can show what shipped
    /// (or what failed) without the user having to scroll review traces.
    @ObservationIgnored
    weak var actionLog: ActionLogStore?

    /// AI-triage history sink. Appends one row per terminal triage
    /// (completed or failed). Owns the spend ledger queried by the
    /// daily-cost-cap check. Weak: the store outlives this worker.
    @ObservationIgnored
    weak var reviewLog: ReviewLogStore?

    /// Hook fired after a successful auto-review post so the inbox row
    /// reflects the new reviewDecision without waiting for the next 60s
    /// poll. Wired to `PRPoller.refreshPR` from `AppDelegate`.
    @ObservationIgnored
    var onAutoReviewPosted: (@MainActor (_ pr: InboxPR) -> Void)?

    /// One decided-but-not-yet-posted auto review. Body and inline
    /// comments are resolved at staging time, while the run's diff is
    /// still in hand — `fireBatch` runs minutes later and has no diff.
    struct StagedAutoReview: Sendable, Hashable, Identifiable {
        var id: String { pr.nodeId }
        let pr: InboxPR
        let review: AggregatedReview
        /// The GitHub review action to post. Nil for `.flagOnly` denials,
        /// which never reach `fireBatch`.
        let action: ReviewActionKind?
        let body: String
        let comments: [GHClient.InlineComment]
        let stagedAt: Date
        /// Distinguishes a share from an auto-approve/deny post. Both post
        /// the same COMMENT event with the same body shape, so the source
        /// is the only thing that tells them apart downstream.
        var source: ActionSource = .automated
    }

    init(
        diffFetcher: @escaping @Sendable (_ owner: String, _ repo: String, _ number: Int) async throws -> String,
        checkoutManager: RepoCheckoutManager? = nil,
        cache: ReviewCache? = nil,
        failureLogStore: FailureLogStore? = nil
    ) {
        self.diffFetcher = diffFetcher
        self.checkoutManager = checkoutManager
        self.cache = cache
        self.failureLogStore = failureLogStore
        if let cache {
            // Restore prior reviews so a relaunch doesn't wipe them.
            // In-flight states from a crashed previous run are downgraded
            // to .failed("interrupted") — the user can hit Re-run.
            self.reviews = cache.load().mapValues { state in
                if state.status.isInFlight {
                    var s = state
                    s.status = .failed("Interrupted by previous app exit. Press Re-run.")
                    return s
                }
                return state
            }
        }
    }

    /// Convenience: real GHClient-backed worker with a real checkout manager.
    static func live() -> ReviewQueueWorker {
        let client = try? GHClient()
        let checkout = RepoCheckoutManager()
        let worker = ReviewQueueWorker(
            diffFetcher: { owner, repo, number in
                let c = try client ?? GHClient()
                return try await c.fetchDiff(owner: owner, repo: repo, number: number)
            },
            checkoutManager: checkout,
            cache: ReviewCache.live(),
            failureLogStore: FailureLogStore.live()
        )
        worker.reviewThreadFetcher = { owner, repo, number in
            let c = try client ?? GHClient()
            return try await c.fetchReviewThreads(owner: owner, repo: repo, number: number)
        }
        return worker
        // reviewLog is wired separately by AppDelegate so all stores
        // share one ModelContainer (sharing the container keeps SwiftData
        // notifications consistent across @Query consumers).
    }

    /// Test/preview only: pre-populate the reviews map without going
    /// through the queue. Used by ScreenshotTests.
    func _setReviewsForScreenshot(_ reviews: [String: ReviewState]) {
        self.reviews = reviews
    }

    /// Test/preview only: pre-seed live progress so screenshots can
    /// capture the in-flight UI deterministically.
    func _setLiveProgressForScreenshot(_ progress: [String: ReviewProgress]) {
        self.liveProgress = progress
    }

    /// Save the current `reviews` map to disk if a cache is wired.
    private func persist() {
        cache?.save(reviews)
    }

    /// Enqueue a PR for review. Idempotent — already-known PR is a no-op
    /// unless `force = true` (re-run). `providerOverride` lets a single
    /// run target a non-default backend (e.g. PRDetailView "Re-run with
    /// codex"); nil falls back to the repo + app defaults.
    func enqueue(_ pr: InboxPR, force: Bool = false, providerOverride: ProviderID? = nil) {
        let cfg = configResolver(pr.owner, pr.repo)
        // Repo-level exclusion — silent skip, no review state recorded.
        if cfg.excluded {
            PRBarLog.triage.notice("enqueue skip reason=excluded pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public)")
            return
        }
        if !force, let existing = reviews[pr.nodeId], !existing.status.isTerminal {
            PRBarLog.triage.debug("enqueue skip reason=in-flight pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public)")
            return
        }
        // Cache hit + same SHA → reuse the verdict. Cache hit + different
        // SHA → auto re-triage (the PR moved). Cache miss → fresh run.
        if !force, let existing = reviews[pr.nodeId], existing.status.isTerminal {
            if existing.headSha == pr.headSha, case .completed = existing.status {
                // Already have a fresh verdict for this exact commit, but
                // the readiness coordinator still needs the "settled" pulse
                // so it knows this PR is human-ready (otherwise restarts
                // with persisted reviews never trigger a notification).
                let settled = inFlight == 0 && pending.isEmpty
                PRBarLog.triage.notice("enqueue cache-hit pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public) sha=\(self.short(pr.headSha), privacy: .public) settled=\(settled, privacy: .public)")
                onReviewSettled?(pr.nodeId, settled)
                return
            }
            // SHA mismatch or previously failed → fall through to re-queue.
        }
        // If we already had a completed review for an earlier SHA, fold
        // it into the new entry's `priorReviews` chain. The chain
        // accumulates across multiple head-moves the user never posted,
        // so the model gets the full history of internal drafts and can
        // produce one consolidated final review for the current state.
        // `forceFullReview` opts out — model re-evaluates from scratch.
        let priorChain: [PriorReview] = {
            guard let existing = reviews[pr.nodeId],
                  case .completed(let agg) = existing.status,
                  existing.headSha != pr.headSha
            else { return reviews[pr.nodeId]?.priorReviews ?? [] }
            // Cap to the most recent 5 to keep prompt size bounded on
            // long-lived PRs with many force-pushes.
            let appended = (reviews[pr.nodeId]?.priorReviews ?? []) +
                [PriorReview(headSha: existing.headSha, aggregated: agg)]
            return Array(appended.suffix(5))
        }()
        let priorDroppedByFullReview = !priorChain.isEmpty && cfg.forceFullReview
        let priorReviews = cfg.forceFullReview ? [] : priorChain

        // Resolve provider at enqueue time so UI can show "Reviewing
        // with codex…" while the run is queued. Per-run override > repo
        // override > app default.
        let resolvedProviderId = providerOverride
            ?? cfg.providerOverride
            ?? defaultProviderId

        if dailyCostCapEnabled && cumulativeSpend() >= dailyCostCap {
            PRBarLog.triage.notice("enqueue blocked reason=daily-cap pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public) cap=\(self.fmt(self.dailyCostCap), privacy: .public)")
            let now = Date()
            let capMessage = "Daily $\(String(format: "%.2f", dailyCostCap)) cap reached. "
                + "Raise it in Settings → General."
            reviews[pr.nodeId] = ReviewState(
                prNodeId: pr.nodeId,
                providerId: resolvedProviderId,
                headSha: pr.headSha,
                triggeredAt: now,
                status: .failed(capMessage),
                costUsd: 0,
                priorReviews: priorReviews
            )
            persist()
            reviewLog?.recordFailed(
                pr: pr,
                headSha: pr.headSha,
                providerId: resolvedProviderId,
                triggeredAt: now,
                completedAt: now,
                errorMessage: capMessage,
                costUsd: 0
            )
            return
        }
        reviews[pr.nodeId] = ReviewState(
            prNodeId: pr.nodeId,
            providerId: resolvedProviderId,
            headSha: pr.headSha,
            triggeredAt: Date(),
            status: .queued,
            costUsd: 0,
            priorReviews: priorReviews
        )
        let priorTag: String = {
            if priorReviews.isEmpty {
                return priorDroppedByFullReview ? "prior=dropped(forceFullReview)" : "prior=none"
            }
            let shas = priorReviews.map { self.short($0.headSha) }.joined(separator: ",")
            return "prior=[\(shas)]"
        }()
        PRBarLog.triage.notice("enqueue queued pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public) sha=\(self.short(pr.headSha), privacy: .public) provider=\(resolvedProviderId.rawValue, privacy: .public) force=\(force, privacy: .public) \(priorTag, privacy: .public)")
        persist()
        pending.append(PendingItem(pr: pr, providerOverride: providerOverride))
        drainIfPossible()
    }

    /// Auto-enqueue any review-requested PR we haven't seen before. Wired
    /// from `PRPoller` after each successful poll. Intentionally idempotent
    /// — repeat polls are no-ops.
    func enqueueNewReviewRequests(from prs: [InboxPR]) {
        for pr in prs where pr.role == .reviewRequested || pr.role == .both {
            let cfg = configResolver(pr.owner, pr.repo)
            // Repo opted out of AI triage entirely → ReadinessCoordinator
            // marks these as "ready" immediately on the human side.
            if !cfg.aiReviewEnabled {
                PRBarLog.triage.debug("auto-enqueue skip reason=ai-disabled pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public)")
                recordSkip(pr, reason: .aiReviewDisabled)
                continue
            }
            // Skip drafts unless the repo config opts in — drafts churn a
            // lot and reviewing them burns cost on intermediate state.
            if pr.isDraft && !cfg.reviewDrafts {
                PRBarLog.triage.debug("auto-enqueue skip reason=draft pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public)")
                recordSkip(pr, reason: .draftNotReviewed)
                continue
            }
            // Skip the AI run when another human already reviewed — it's
            // covered, so don't burn cost re-triaging. Inbox visibility is
            // governed separately by the opt-in hide filter (same predicate);
            // manual Re-run still works regardless.
            if cfg.skipAIIfReviewedByOthers && pr.isReviewedByOthers {
                PRBarLog.triage.debug("auto-enqueue skip reason=already-reviewed-by-others pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public) decision=\(pr.reviewDecision ?? "nil", privacy: .public)")
                recordSkip(pr, reason: .reviewedByOthers)
                continue
            }
            // A review that already failed at this exact commit is not
            // auto-retried — re-running on the next poll either burns cost
            // re-failing deterministically (budgetExceeded on a too-large
            // diff) or churns the UI for transient failures, and it masks
            // the failed state as the row flips back to "Reviewing…". Any
            // failure is terminal for this SHA; a new commit re-arms it and
            // manual Re-run (force) bypasses this.
            if let existing = reviews[pr.nodeId],
               case .failed = existing.status,
               existing.headSha == pr.headSha {
                PRBarLog.triage.debug("auto-enqueue skip reason=failed-at-current-sha pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public) sha=\(self.short(pr.headSha), privacy: .public)")
                continue
            }
            enqueue(pr)
        }
    }

    /// Record a deliberate auto-triage skip so the row/detail UI can show
    /// *why* a review-requested PR wasn't reviewed, instead of a perpetual
    /// "not started". Keyed at the PR's current head — a new commit re-arms
    /// (the stale-SHA entry is replaced on the next poll). Never masks a
    /// real review already recorded for this head (in-flight, completed, or
    /// failed — e.g. a manual Re-run), and is a no-op when the same skip is
    /// already recorded so repeat polls don't churn `reviews` / persistence.
    private func recordSkip(_ pr: InboxPR, reason: ReviewState.SkipReason) {
        if let existing = reviews[pr.nodeId], existing.headSha == pr.headSha {
            switch existing.status {
            case .queued, .running, .completed, .failed:
                return
            case .skipped(let current) where current == reason:
                return
            case .skipped:
                break
            }
        }
        let cfg = configResolver(pr.owner, pr.repo)
        reviews[pr.nodeId] = ReviewState(
            prNodeId: pr.nodeId,
            providerId: cfg.providerOverride ?? defaultProviderId,
            headSha: pr.headSha,
            triggeredAt: Date(),
            status: .skipped(reason),
            costUsd: 0
        )
        persist()
    }

    /// Spend used by the daily cap. Queries the `ReviewLog` ledger for
    /// rows with `triggeredAt >= startOfLocalDay`. Local-calendar reset
    /// (not UTC) — a user's "today" matches their work day. Falls back
    /// to the in-memory `reviews` total if the log isn't wired (tests
    /// that don't construct a store).
    func cumulativeSpend() -> Double {
        if let log = reviewLog {
            return log.todaysSpend()
        }
        return reviews.values.reduce(0) { $0 + $1.costUsd }
    }

    // MARK: - private

    private func drainIfPossible() {
        // Pop newest-first (highest PR number) rather than FIFO so a stale
        // older PR I'm not planning to approve doesn't block fresh review
        // requests behind it. PR number is a per-repo monotonic stand-in
        // for createdAt; cross-repo it's an arbitrary-but-stable tiebreaker,
        // which matches the user-stated "all other things equal" intent.
        while inFlight < maxConcurrent, !pending.isEmpty {
            let idx = pending.indices.max { pending[$0].pr.number < pending[$1].pr.number }!
            let next = pending.remove(at: idx)
            inFlight += 1
            Task { await self.run(item: next) }
        }
    }

    private func run(item: PendingItem) async {
        let pr = item.pr
        let runStart = Date()
        // Triage start time is what gets logged as `triggeredAt` on the
        // history row — the moment the run was committed, not when it
        // finished. Pulled from the in-memory state (set by enqueue) so
        // a worker restart doesn't lose the original timestamp.
        let triggeredAt = reviews[pr.nodeId]?.triggeredAt ?? runStart
        let provId = reviews[pr.nodeId]?.providerId ?? defaultProviderId
        // Hoisted out of the do-block so the catch branch can sum cost
        // from subreviews that completed before the throw — otherwise a
        // mid-run failure under-reports against the daily cap.
        var completedOutcomes: [SubreviewOutcome] = []
        defer {
            inFlight -= 1
            drainIfPossible()
            // Fire after the in-flight counter is decremented so listeners
            // see the post-decrement settled state. "Settled" means the
            // queue is fully idle — no in-flight, no pending.
            let settled = inFlight == 0 && pending.isEmpty
            onReviewSettled?(pr.nodeId, settled)
        }

        reviews[pr.nodeId]?.status = .running
        persist()

        do {
            let config = configResolver(pr.owner, pr.repo)
            if config.excluded {
                PRBarLog.triage.notice("run abort reason=excluded pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public)")
                let msg = "Repo \(pr.owner)/\(pr.repo) is excluded by config."
                reviews[pr.nodeId]?.status = .failed(msg)
                reviewLog?.recordFailed(
                    pr: pr, headSha: pr.headSha, providerId: provId,
                    triggeredAt: triggeredAt, errorMessage: msg, costUsd: 0
                )
                return
            }
            let diffText = try await diffFetcher(pr.owner, pr.repo, pr.number)
            // Provider resolution: per-run override > repo override > app default.
            let chosenProviderId = item.providerOverride
                ?? config.providerOverride
                ?? defaultProviderId
            let resolvedModel = resolveModel(providerId: chosenProviderId, config: config)
            let resolvedEffort = resolveEffort(providerId: chosenProviderId, config: config)
            var effectiveToolMode = config.toolMode
            // `.sandboxed` works for both providers: claude via its
            // `--settings` Seatbelt sandbox, codex via `exec --sandbox
            // read-only`. Both explore the worktree with git instead of an
            // inlined diff. Falls back to `.none` only when no checkout can
            // be provisioned (handled below).
            let subdiffs = MonorepoSplitter.split(diffText: diffText, config: config, toolMode: effectiveToolMode)
            guard !subdiffs.isEmpty else {
                PRBarLog.triage.notice("run abort reason=empty-diff pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public)")
                let msg = "Empty diff — nothing to review."
                reviews[pr.nodeId]?.status = .failed(msg)
                reviewLog?.recordFailed(
                    pr: pr, headSha: pr.headSha, providerId: provId,
                    triggeredAt: triggeredAt, errorMessage: msg, costUsd: 0
                )
                return
            }
            let priorAtStart = reviews[pr.nodeId]?.priorReviews ?? []
            let subpathSummary = subdiffs.map { $0.subpath.isEmpty ? "<root>" : $0.subpath }.joined(separator: ",")
            PRBarLog.triage.notice("run start pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public) sha=\(self.short(pr.headSha), privacy: .public) toolMode=\(effectiveToolMode.rawValue, privacy: .public) split=\(config.splitMode.rawValue, privacy: .public) subdiffs=\(subdiffs.count, privacy: .public) subpaths=[\(subpathSummary, privacy: .public)] priorChain=\(priorAtStart.count, privacy: .public) diffBytes=\(diffText.utf8.count, privacy: .public)")

            // Provision one worktree at the PR's head and reuse it across
            // all subreviews (same SHA, different subpaths). `.sandboxed`
            // additionally fetches the base so the agent can diff offline.
            // The worktree is a full checkout (no sparse cone) so the agent
            // can read any referenced file with plain Read/Grep.
            var sharedHandle: RepoCheckoutManager.Handle? = nil
            if effectiveToolMode == .minimal || effectiveToolMode == .sandboxed,
               let mgr = checkoutManager {
                do {
                    sharedHandle = try await mgr.provision(
                        owner: pr.owner, repo: pr.repo,
                        headSha: pr.headSha, subpath: "",
                        baseRef: effectiveToolMode == .sandboxed ? pr.baseRef : "",
                        historyDepth: config.riskBriefEnabled && config.churnWindowDays > 0
                            ? config.churnHistoryDepth
                            : RepoCheckoutManager.defaultHistoryDepth
                    )
                } catch {
                    // Checkout unavailable (no git/gh, network, etc.) — degrade
                    // to the inlined-diff path so the review still runs.
                    PRBarLog.triage.error("provision failed pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public) — falling back to inline diff: \(String(describing: error), privacy: .public)")
                    effectiveToolMode = .none
                }
            }
            if effectiveToolMode == .sandboxed && sharedHandle == nil {
                effectiveToolMode = .none
            }
            defer {
                if let h = sharedHandle, let mgr = checkoutManager {
                    Task { await mgr.release(h) }
                }
            }

            let priorChainForPrompt = reviews[pr.nodeId]?.priorReviews ?? []
            let prNodeId = pr.nodeId

            // Pull the tail of every failed Actions job so the AI sees
            // *why* CI failed, not just that it did. Best-effort: any
            // log we can't fetch (legacy StatusContext, missing job id,
            // permissions) is silently skipped — the AI still gets the
            // CI status rollup. The store also caches the tails so
            // PRDetailView's expandable failure log doesn't refetch.
            let ciFailures: [CIFailureLog]
            if let store = failureLogStore,
               pr.allCheckSummaries.contains(where: { $0.bucket == .failed }) {
                ciFailures = await store.fetchAllFailures(for: pr)
            } else {
                ciFailures = []
            }

            let chosenProvider: ReviewProvider
            if let lookup = providerLookup {
                chosenProvider = lookup(chosenProviderId)
            } else {
                chosenProvider = provider
            }
            // Commit history for the risk brief's churn term. Read once per
            // run (not per subdiff) — it's a single `git log` over the whole
            // worktree and every subdiff indexes into the same map. Needs a
            // checkout; without one the brief still ships, minus churn.
            var churn: ChurnWindow? = nil
            var markedGenerated: Set<String> = []
            if config.riskBriefEnabled, let handle = sharedHandle {
                if config.churnWindowDays > 0 {
                    churn = await churnFetcher(handle.worktreePath, config.churnWindowDays)
                }
                // One scan across every subdiff's files — the same file can't
                // appear in two subdiffs, and one pass keeps the ceiling in
                // `GeneratedCodeScanner.maxFilesScanned` PR-wide.
                let allPaths = subdiffs.flatMap(\.filePaths)
                markedGenerated = await generatedScanner(allPaths, handle.worktreePath)
            }

            // Local alias for the loop; the outer `completedOutcomes`
            // is what survives a throw. We append to both in lockstep.
            var outcomes: [SubreviewOutcome] = []
            for subdiff in subdiffs {
                let workdir = resolveWorkdir(handle: sharedHandle, subpath: subdiff.subpath)
                let bundle = try ContextAssembler.assemble(
                    pr: pr,
                    subdiff: subdiff,
                    diffText: diffText,
                    ciFailures: ciFailures,
                    toolMode: effectiveToolMode,
                    workdir: workdir,
                    baseSha: sharedHandle?.baseSha ?? "",
                    customSystemPrompt: config.customSystemPrompt,
                    replaceBaseSystemPrompt: config.replaceBaseSystemPrompt,
                    priorReviews: priorChainForPrompt,
                    riskBrief: config.riskBriefEnabled
                        ? RiskBrief.compute(
                            subdiff: subdiff,
                            churn: churn,
                            markedGenerated: markedGenerated
                        )
                        : nil
                )
                let options = ProviderOptions(
                    model: resolvedModel,
                    effort: resolvedEffort,
                    toolMode: effectiveToolMode,
                    additionalAddDirs: [],
                    repoBarePath: sharedHandle?.barePath,
                    maxToolCalls: config.maxToolCallsPerSubreview,
                    maxCostUsd: config.maxCostUsdPerSubreview,
                    timeout: .seconds(config.reviewTimeoutSeconds),
                    schema: try PromptLibrary.outputSchema()
                )
                let subStart = Date()
                let result = try await chosenProvider.review(
                    bundle: bundle,
                    options: options,
                    onProgress: { progress in
                        // Hop to the main actor since liveProgress is
                        // observed by SwiftUI views.
                        Task { @MainActor [weak self] in
                            self?.liveProgress[prNodeId] = progress
                        }
                    }
                )
                let subElapsedMs = Int(Date().timeIntervalSince(subStart) * 1000)
                let subpathTag = subdiff.subpath.isEmpty ? "<root>" : subdiff.subpath
                PRBarLog.provider.notice("subreview done pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public) subpath=\(subpathTag, privacy: .public) verdict=\(result.verdict.rawValue, privacy: .public) confidence=\(self.fmt(result.confidence), privacy: .public) cost=\(self.fmt(result.costUsd ?? 0), privacy: .public) tools=\(result.toolCallCount, privacy: .public) elapsedMs=\(subElapsedMs, privacy: .public)")
                let outcome = SubreviewOutcome(subpath: subdiff.subpath, result: result)
                outcomes.append(outcome)
                completedOutcomes.append(outcome)
            }
            // Clear live progress once outcomes are aggregated below.
            liveProgress[prNodeId] = nil

            // Sum of costUsd across subreviews completed so far. Used as
            // best-effort cost reporting if the run fails after one or
            // more subreviews succeeded — the user pays for those even
            // when a later subreview blows up. Computed live so it's
            // available in both the no-aggregate and catch branches.
            let partialSpend = completedOutcomes.compactMap { $0.result.costUsd }.reduce(0, +)

            guard let aggregated = ResultAggregator.aggregate(outcomes) else {
                PRBarLog.triage.error("run abort reason=no-aggregate pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public)")
                let msg = "No subreviews aggregated."
                reviews[pr.nodeId]?.status = .failed(msg)
                reviewLog?.recordFailed(
                    pr: pr, headSha: pr.headSha, providerId: provId,
                    triggeredAt: triggeredAt, errorMessage: msg,
                    costUsd: partialSpend > 0 ? partialSpend : nil
                )
                return
            }
            let runElapsedMs = Int(Date().timeIntervalSince(runStart) * 1000)
            PRBarLog.triage.notice("run done pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public) sha=\(self.short(pr.headSha), privacy: .public) verdict=\(aggregated.verdict.rawValue, privacy: .public) confidence=\(self.fmt(aggregated.confidence), privacy: .public) cost=\(self.fmt(aggregated.costUsd), privacy: .public) annotations=\(aggregated.annotations.count, privacy: .public) elapsedMs=\(runElapsedMs, privacy: .public)")
            reviews[pr.nodeId]?.status = .completed(aggregated)
            reviews[pr.nodeId]?.costUsd = aggregated.costUsd
            // Don't clear the chain on success — the previous draft is
            // still "unposted from the user's perspective" until they
            // actually push a review to GitHub. The chain naturally caps
            // at 5 in `enqueue` so it can't grow unbounded.
            persist()
            reviewLog?.recordCompleted(
                pr: pr, headSha: pr.headSha, providerId: provId,
                triggeredAt: triggeredAt, review: aggregated
            )
            stageAutoReviewIfEligible(
                pr: pr, review: aggregated, config: config,
                providerId: chosenProviderId, diffText: diffText
            )
            await resolveAddressedThreads(pr: pr, review: aggregated, config: config)
        } catch {
            PRBarLog.triage.error("run failed pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public) error=\(String(describing: error), privacy: .public)")
            reviews[pr.nodeId]?.status = .failed(error.localizedDescription)
            liveProgress[pr.nodeId] = nil
            persist()
            // Cost from any subreviews that completed before the throw
            // counts toward the daily cap. Without this, a 5-subreview
            // PR that errors on subreview 4 reports $0 even though we
            // already paid for the first three.
            let partialSpend = completedOutcomes.compactMap { $0.result.costUsd }.reduce(0, +)
            reviewLog?.recordFailed(
                pr: pr, headSha: pr.headSha, providerId: provId,
                triggeredAt: triggeredAt,
                errorMessage: error.localizedDescription,
                costUsd: partialSpend > 0 ? partialSpend : nil
            )
        }
    }

    /// First 7 chars of a SHA, or `<empty>` when blank. Lifted out so
    /// every log call doesn't repeat the slice + guard inline.
    private nonisolated func short(_ sha: String) -> String {
        if sha.isEmpty { return "<empty>" }
        return String(sha.prefix(7))
    }

    /// Format a Double for log output. `OSLogInterpolation` doesn't have
    /// a `(_ value: Double, privacy:)` overload — only String / Int /
    /// Bool / NSObject — so we stringify here and pass the result as a
    /// String interpolation. Three-decimal precision is enough for cost
    /// (cents) and confidence (per-mille).
    private nonisolated func fmt(_ d: Double) -> String {
        String(format: "%.3f", d)
    }

    /// Compute the cwd for a subreview. In `.minimal` mode with a shared
    /// worktree, that's `<worktree>/<subpath>` (or worktree root for the
    /// trivial single-subdiff case). In `.none` mode, just an empty temp
    /// dir per subreview — there's nothing to read either way.

    private func resolveWorkdir(handle: RepoCheckoutManager.Handle?, subpath: String) -> URL {
        if let handle {
            return subpath.isEmpty
                ? handle.worktreePath
                : handle.worktreePath.appendingPathComponent(subpath, isDirectory: true)
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("prbar-review-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    /// Close the review threads this triage considers dealt with.
    ///
    /// Runs after every completed triage, not just after a share: threads
    /// PRBar opened via auto-deny inline comments deserve the same
    /// treatment, and the gate in `ReviewThreadResolver` is what decides
    /// eligibility, not the caller.
    ///
    /// Three things have to line up before anything is queued, and each
    /// guards a different way this can be wrong:
    ///
    /// - **Opt-in.** Resolving collapses a thread for every human on the
    ///   PR, so it is never inherited silently. `ResolveThreadsConfig`
    ///   ships off.
    /// - **Confidence.** The signal that closes a thread is a finding's
    ///   *absence*, which is also what a degraded run produces. A run
    ///   under the floor closes nothing.
    /// - **Head SHA.** Threads are read live but the annotations come from
    ///   the commit this triage ran on. If the author pushed while the
    ///   review was running, GitHub's `isOutdated` reflects *their* push
    ///   while our findings describe the previous head — stale findings
    ///   would close threads on code nobody has reviewed yet.
    ///
    /// The resolve itself goes through `ActionQueue` like every other
    /// GitHub write, so it is serialized against this PR's other writes,
    /// retryable, and visible in History.
    private func resolveAddressedThreads(
        pr: InboxPR,
        review: AggregatedReview,
        config: ResolvedRepoConfig
    ) async {
        let policy = config.resolveThreads
        guard policy.enabled else { return }
        guard let fetcher = reviewThreadFetcher else { return }
        guard review.confidence >= policy.minConfidence else {
            PRBarLog.triage.notice("thread resolve skipped pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public) reason=low-confidence conf=\(self.fmt(review.confidence), privacy: .public)")
            return
        }
        do {
            let page = try await fetcher(pr.owner, pr.repo, pr.number)
            guard page.headRefOid == pr.headSha else {
                PRBarLog.triage.notice("thread resolve skipped pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public) reason=head-moved reviewed=\(self.short(pr.headSha), privacy: .public) now=\(self.short(page.headRefOid), privacy: .public)")
                return
            }
            let targets = ReviewThreadResolver.resolvable(
                threads: page.threads,
                annotations: review.annotations,
                viewerLogin: page.viewerLogin,
                prAuthor: pr.author
            )
            guard !targets.isEmpty else { return }
            PRBarLog.triage.notice("thread resolve queued pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public) count=\(targets.count, privacy: .public)")
            enqueueResolveThreads?(pr, targets.map(\.id))
        } catch {
            PRBarLog.triage.error("thread fetch failed pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - auto-review batching

    /// Evaluate both auto-review sides and stage whatever clears. Called
    /// with the run's `diffText` still in scope so inline comments can be
    /// correlated against the diff now — `fireBatch` runs after the undo
    /// window and no longer has one.
    private func stageAutoReviewIfEligible(
        pr: InboxPR,
        review: AggregatedReview,
        config: ResolvedRepoConfig,
        providerId: ProviderID,
        diffText: String
    ) {
        // A fresh verdict supersedes whatever the previous run decided for
        // this PR — including a still-counting-down staged post from an
        // older SHA, which would otherwise fire against a review nobody
        // holds anymore.
        pendingAutoActions[pr.nodeId] = nil
        flaggedDenials[pr.nodeId] = nil
        // Removing the last entry mid-countdown would otherwise leave the
        // banner ticking down to a batch with nothing in it.
        if batchUndoActive && pendingAutoActions.isEmpty {
            cancelAutoReviewBatch()
        }

        let decision = AutoReviewPolicy.evaluate(
            pr: pr, review: review, providerId: providerId, config: config
        )
        switch decision {
        case .skip(let reason):
            PRBarLog.triage.debug("auto-review skip pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public) reason=\(reason, privacy: .public)")
        case .approve:
            let cfg = config.autoApprove
            let staged = StagedAutoReview(
                pr: pr,
                review: review,
                action: .approve,
                // Empty body = a bare GitHub approval, which is what the
                // green check already says. The attribution line is opt-in
                // because it lands as a comment on every PR the bot touches.
                body: cfg.postAttributionComment ? attributionBody(review) : "",
                comments: cfg.postInlineAnnotations
                    ? inlineComments(review: review, diffText: diffText)
                    : [],
                stagedAt: Date()
            )
            pendingAutoActions[pr.nodeId] = staged
            PRBarLog.triage.notice("auto-review staged pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public) action=approve comments=\(staged.comments.count, privacy: .public)")
            scheduleBatchIfSettled()
        case .share:
            // Only the annotations the policy actually asked for — sharing
            // "warnings and blockers" while posting every nitpick inline
            // would contradict the setting the user chose.
            let floor = config.shareFindings.minSeverity ?? .info
            // Severity first, then the cap — so a truncated share keeps the
            // findings that matter most rather than whichever the model
            // happened to emit first.
            var shared = review.annotations
                .filter { $0.severity >= floor }
                .sorted { $0.severity > $1.severity }
            let cap = config.shareMaxComments
            if cap > 0 && shared.count > cap {
                PRBarLog.triage.notice("share capped pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public) found=\(shared.count, privacy: .public) cap=\(cap, privacy: .public)")
                shared = Array(shared.prefix(cap))
            }
            let comments = inlineComments(annotations: shared, diffText: diffText)
            let staged = StagedAutoReview(
                pr: pr,
                review: review,
                action: .comment,
                // Findings that landed inline are the whole review — a body
                // on top of them can only restate the diff back to the
                // author. GitHub accepts an empty body on a COMMENT review
                // that carries inline comments; it rejects one that carries
                // none, so the summary stays as the body in that case, where
                // dropping it would post nothing at all.
                body: comments.isEmpty ? shareBody(review) : "",
                comments: comments,
                stagedAt: Date(),
                source: .sharedFindings
            )
            pendingAutoActions[pr.nodeId] = staged
            PRBarLog.triage.notice("auto-review staged pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public) action=share comments=\(staged.comments.count, privacy: .public)")
            scheduleBatchIfSettled()
        case .deny(let denyAction):
            let cfg = config.autoDeny
            let comments = cfg.postInlineAnnotations
                ? inlineComments(review: review, diffText: diffText)
                : []
            let staged = StagedAutoReview(
                pr: pr,
                review: review,
                action: denyAction.reviewActionKind,
                // GitHub rejects an empty body on REQUEST_CHANGES and
                // COMMENT, so the AI summary is the body — falling back to
                // the attribution line only if the summary came back blank.
                body: review.summaryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? denyFallbackBody(review)
                    : review.summaryMarkdown,
                comments: comments,
                stagedAt: Date()
            )
            if denyAction == .flagOnly {
                flaggedDenials[pr.nodeId] = staged
                PRBarLog.triage.notice("auto-review flagged pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public)")
            } else {
                pendingAutoActions[pr.nodeId] = staged
                PRBarLog.triage.notice("auto-review staged pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public) action=\(denyAction.rawValue, privacy: .public) comments=\(comments.count, privacy: .public)")
                scheduleBatchIfSettled()
            }
        }
    }

    private func inlineComments(review: AggregatedReview, diffText: String) -> [GHClient.InlineComment] {
        inlineComments(annotations: review.annotations, diffText: diffText)
    }

    private func inlineComments(
        annotations: [DiffAnnotation],
        diffText: String
    ) -> [GHClient.InlineComment] {
        guard !annotations.isEmpty else { return [] }
        return InlineCommentMapper.map(
            annotations: annotations,
            hunks: DiffParser.parse(diffText)
        )
    }

    /// Start the undo-window timer iff (a) we have staged posts and
    /// (b) no review is still in-flight. The "wait until everything is
    /// settled" rule deliberately collapses many notifications into one.
    private func scheduleBatchIfSettled() {
        guard !batchUndoActive else { return }
        guard !pendingAutoActions.isEmpty else { return }
        let anyInFlight = reviews.values.contains { $0.status.isInFlight }
        guard !anyInFlight else { return }

        batchUndoActive = true
        batchUndoDeadline = Date().addingTimeInterval(undoWindow)
        let window = undoWindow
        batchTimer?.cancel()
        batchTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(window))
            await MainActor.run { self?.fireBatch() }
        }
    }

    /// User-pressed "Undo" — discard the staged batch.
    func cancelAutoReviewBatch() {
        batchTimer?.cancel()
        batchTimer = nil
        pendingAutoActions.removeAll()
        batchUndoActive = false
        batchUndoDeadline = nil
    }

    /// User-pressed "Post now" — fire immediately instead of waiting.
    func fireAutoReviewBatchNow() {
        batchTimer?.cancel()
        batchTimer = nil
        fireBatch()
    }

    /// Dismiss a flag-only denial the user has looked at.
    func dismissFlaggedDenial(_ nodeId: String) {
        flaggedDenials[nodeId] = nil
    }

    func dismissAllFlaggedDenials() {
        flaggedDenials.removeAll()
    }

    private func fireBatch() {
        let toPost = Array(pendingAutoActions.values)
        pendingAutoActions.removeAll()
        batchUndoActive = false
        batchUndoDeadline = nil
        for entry in toPost {
            guard let action = entry.action else { continue }
            // Production: route through the shared ActionQueue so the post
            // is serialized + dedup'd + retryable + logged on the one path.
            // The queue records its own ActionLog entry and triggers the
            // PR refresh via onActionCompleted, so we don't duplicate that
            // here.
            if let enqueueAutoReview {
                enqueueAutoReview(
                    entry.pr, action, entry.body, entry.comments,
                    entry.review.costUsd, entry.source
                )
                continue
            }
            // Fallback (tests / no queue wired): post inline.
            Task { [poster = autoReviewPoster, weak self] in
                do {
                    try await poster(entry.pr, action, entry.body, entry.comments)
                    await MainActor.run {
                        self?.actionLog?.record(
                            kind: Self.autoLogKind(action, entry.source), outcome: .success, pr: entry.pr,
                            detail: entry.body, headSha: entry.pr.headSha,
                            costUsd: entry.review.costUsd
                        )
                        self?.onAutoReviewPosted?(entry.pr)
                    }
                } catch {
                    await MainActor.run {
                        self?.actionLog?.record(
                            kind: Self.autoLogKind(action, entry.source), outcome: .failure, pr: entry.pr,
                            errorMessage: error.localizedDescription,
                            detail: entry.body, headSha: entry.pr.headSha,
                            costUsd: entry.review.costUsd
                        )
                    }
                }
            }
        }
    }

    /// Body for a `.share` post: the AI summary verbatim, exactly like the
    /// auto-deny comment path. No banner or disclaimer — a shared review
    /// should be indistinguishable from any other review PRBar posts.
    /// GitHub rejects an empty body on COMMENT, hence the fallback.
    private func shareBody(_ review: AggregatedReview) -> String {
        let summary = review.summaryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? shareFallbackBody(review) : summary
    }

    private func shareFallbackBody(_ review: AggregatedReview) -> String {
        "PRBar's AI review flagged the findings below (\(formatConfidence(review.confidence)) confidence) but returned no summary."
    }

    /// Log kind for the fallback (no `ActionQueue` wired) post path.
    /// `ActionQueue.logKindAndDetail` is the production equivalent; both
    /// have to agree or a share reads as a plain auto-comment in History.
    private nonisolated static func autoLogKind(
        _ action: ReviewActionKind,
        _ source: ActionSource
    ) -> ActionLogKind {
        source == .sharedFindings ? .autoShare : action.autoActionLogKind
    }

    private func attributionBody(_ review: AggregatedReview) -> String {
        "Auto-approved by PRBar (\(formatConfidence(review.confidence)) confidence)."
    }

    private func denyFallbackBody(_ review: AggregatedReview) -> String {
        "PRBar's AI review requested changes (\(formatConfidence(review.confidence)) confidence) but returned no summary. See the annotations."
    }

    private func formatConfidence(_ c: Double) -> String {
        String(format: "%.0f%%", c * 100)
    }
}
