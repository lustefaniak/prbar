import Foundation
import Observation

/// One pending or completed AI review keyed by PR node ID. Drives the
/// per-row "review status" UI in the inbox and the AI section in the
/// detail pane.
struct ReviewState: Sendable, Hashable, Codable {
    enum Status: Sendable, Hashable, Codable {
        case queued
        case running
        case completed(AggregatedReview)
        case failed(String)

        var isTerminal: Bool {
            switch self {
            case .queued, .running: return false
            case .completed, .failed: return true
            }
        }

        var isInFlight: Bool {
            switch self {
            case .queued, .running: return true
            case .completed, .failed: return false
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

    /// When retriaging because the PR's head moved, the prior completed
    /// review is preserved here so the UI keeps showing the previous
    /// verdict (with a stale banner) and the new run can frame its
    /// prompt as "did the new commits address prior concerns?". Cleared
    /// when the new review completes successfully; on failure the prior
    /// remains so the user doesn't lose their last good triage.
    var priorReview: PriorReview? = nil
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

    /// What tool-access mode the provider runs in.
    var toolMode: ToolMode = .none

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

    /// Resolves the per-repo config used when reviewing a PR. Pluggable so
    /// tests can stub it and runtime can swap the live `RepoConfigStore`.
    /// Default uses the built-in registry only.
    @ObservationIgnored
    var configResolver: @Sendable (_ owner: String, _ repo: String) -> RepoConfig = { owner, repo in
        RepoConfig.match(owner: owner, repo: repo)
    }

    /// On-disk checkout manager. Used in `.minimal` tool mode to give the
    /// AI a real workdir for `Read`/`Grep`. Nil → fall back to empty temp
    /// dirs (which only makes sense in `.none` mode anyway).
    @ObservationIgnored
    var checkoutManager: RepoCheckoutManager?

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

    // MARK: - Auto-approve batch state
    //
    // Approvals stage here when `AutoApprovePolicy` says yes. The undo
    // banner only appears once *all* enqueued reviews have settled
    // (no .queued / .running). Design goal: one context switch per cycle,
    // not one per PR.

    /// PRs the worker would auto-approve, keyed by node ID. Population
    /// happens at completion time; presentation is gated by `batchReady`.
    private(set) var pendingAutoApprovals: [String: PendingAutoApprove] = [:]

    /// True when a batch undo banner is currently counting down (visible
    /// in `PopoverView`). Set by `commitBatch()`, cleared on undo / fire.
    private(set) var batchUndoActive: Bool = false

    /// Wall-clock deadline at which the batch fires. Nil unless the
    /// banner is showing.
    private(set) var batchUndoDeadline: Date? = nil

    /// How long the user has to undo the staged batch. 30 s per PLAN.
    var undoWindow: TimeInterval = 30

    /// Closure that posts the actual `gh pr review --approve`. Injected
    /// so tests don't shell out. Default uses the shared `GHClient`.
    @ObservationIgnored
    var approvePoster: @Sendable (_ pr: InboxPR, _ body: String) async throws -> Void = { pr, body in
        let c = try GHClient()
        try await c.postReview(
            owner: pr.owner, repo: pr.repo, number: pr.number,
            kind: .approve, body: body
        )
    }

    @ObservationIgnored
    private var batchTimer: Task<Void, Never>?

    /// Fired every time a review reaches a terminal state (`.completed`
    /// / `.failed`). The `ReadinessCoordinator` listens here to flip its
    /// "AI-pending" → "ready for human" bit per PR. `isWorkerSettled` is
    /// true when no review is still queued or running after this one.
    @ObservationIgnored
    var onReviewSettled: (@MainActor (_ prNodeId: String, _ isWorkerSettled: Bool) -> Void)?

    struct PendingAutoApprove: Sendable, Hashable {
        let pr: InboxPR
        let review: AggregatedReview
        let stagedAt: Date
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
        return ReviewQueueWorker(
            diffFetcher: { owner, repo, number in
                let c = try client ?? GHClient()
                return try await c.fetchDiff(owner: owner, repo: repo, number: number)
            },
            checkoutManager: checkout,
            cache: ReviewCache(),
            failureLogStore: FailureLogStore.live()
        )
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
        // Repo-level exclusion — silent skip, no review state recorded.
        if configResolver(pr.owner, pr.repo).excluded {
            return
        }
        if !force, let existing = reviews[pr.nodeId], !existing.status.isTerminal {
            return
        }
        // Cache hit + same SHA → reuse the verdict. Cache hit + different
        // SHA → auto re-triage (the PR moved). Cache miss → fresh run.
        if !force, let existing = reviews[pr.nodeId], existing.status.isTerminal {
            if existing.headSha == pr.headSha, case .completed = existing.status {
                return   // already have a fresh verdict for this exact commit
            }
            // SHA mismatch or previously failed → fall through to re-queue.
        }
        // If we already had a completed review for an earlier SHA, keep
        // it as `priorReview` on the new entry. The UI surfaces it with a
        // stale banner during the retriage; the assembler folds the
        // previous verdict + summary into the prompt so the AI knows the
        // PR has been updated since.
        let prior: PriorReview? = {
            guard let existing = reviews[pr.nodeId],
                  case .completed(let agg) = existing.status,
                  existing.headSha != pr.headSha
            else { return nil }
            return PriorReview(headSha: existing.headSha, aggregated: agg)
        }()

        // Resolve provider at enqueue time so UI can show "Reviewing
        // with codex…" while the run is queued. Per-run override > repo
        // override > app default.
        let resolvedProviderId = providerOverride
            ?? configResolver(pr.owner, pr.repo).providerOverride
            ?? defaultProviderId

        if dailyCostCapEnabled && cumulativeSpend() >= dailyCostCap {
            reviews[pr.nodeId] = ReviewState(
                prNodeId: pr.nodeId,
                providerId: resolvedProviderId,
                headSha: pr.headSha,
                triggeredAt: Date(),
                status: .failed("Daily $\(String(format: "%.2f", dailyCostCap)) cap reached."),
                costUsd: 0,
                priorReview: prior
            )
            persist()
            return
        }
        reviews[pr.nodeId] = ReviewState(
            prNodeId: pr.nodeId,
            providerId: resolvedProviderId,
            headSha: pr.headSha,
            triggeredAt: Date(),
            status: .queued,
            costUsd: 0,
            priorReview: prior
        )
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
            if !cfg.aiReviewEnabled { continue }
            // Skip drafts unless the repo config opts in — drafts churn a
            // lot and reviewing them burns cost on intermediate state.
            if pr.isDraft && !cfg.reviewDrafts { continue }
            enqueue(pr)
        }
    }

    /// Cumulative spend across this worker's lifetime (proxy for "today" —
    /// menu-bar apps don't run multi-day so often it's fine for MVP).
    func cumulativeSpend() -> Double {
        reviews.values.reduce(0) { $0 + $1.costUsd }
    }

    // MARK: - private

    private func drainIfPossible() {
        while inFlight < maxConcurrent, let next = pending.first {
            pending.removeFirst()
            inFlight += 1
            Task { await self.run(item: next) }
        }
    }

    private func run(item: PendingItem) async {
        let pr = item.pr
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
                reviews[pr.nodeId]?.status = .failed("Repo \(pr.owner)/\(pr.repo) is excluded by config.")
                return
            }
            let diffText = try await diffFetcher(pr.owner, pr.repo, pr.number)
            let effectiveToolMode = config.toolModeOverride ?? toolMode
            let subdiffs = MonorepoSplitter.split(diffText: diffText, config: config)
            guard !subdiffs.isEmpty else {
                reviews[pr.nodeId]?.status = .failed("Empty diff — nothing to review.")
                return
            }

            // For .minimal mode, provision one worktree at the PR's headSha
            // and reuse it across all subreviews of this PR (they all
            // reference the same SHA, just different subpaths).
            let sharedHandle: RepoCheckoutManager.Handle?
            if effectiveToolMode == .minimal, let mgr = checkoutManager {
                sharedHandle = try await mgr.provision(
                    owner: pr.owner, repo: pr.repo,
                    headSha: pr.headSha, subpath: ""
                )
            } else {
                sharedHandle = nil
            }
            defer {
                if let h = sharedHandle, let mgr = checkoutManager {
                    Task { await mgr.release(h) }
                }
            }

            let prior = reviews[pr.nodeId]?.priorReview
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

            // Provider resolution: per-run override > repo override > app default.
            let chosenProviderId = item.providerOverride
                ?? config.providerOverride
                ?? defaultProviderId
            let chosenProvider: ReviewProvider
            if let lookup = providerLookup {
                chosenProvider = lookup(chosenProviderId)
            } else {
                chosenProvider = provider
            }
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
                    customSystemPrompt: config.customSystemPrompt,
                    replaceBaseSystemPrompt: config.replaceBaseSystemPrompt,
                    priorReview: prior
                )
                let options = ProviderOptions(
                    model: nil,
                    toolMode: effectiveToolMode,
                    additionalAddDirs: [],
                    maxToolCalls: config.maxToolCallsPerSubreview,
                    maxCostUsd: config.maxCostUsdPerSubreview,
                    timeout: .seconds(120),
                    schema: try PromptLibrary.outputSchema()
                )
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
                outcomes.append(SubreviewOutcome(subpath: subdiff.subpath, result: result))
            }
            // Clear live progress once outcomes are aggregated below.
            liveProgress[prNodeId] = nil

            guard let aggregated = ResultAggregator.aggregate(outcomes) else {
                reviews[pr.nodeId]?.status = .failed("No subreviews aggregated.")
                return
            }
            reviews[pr.nodeId]?.status = .completed(aggregated)
            reviews[pr.nodeId]?.costUsd = aggregated.costUsd
            // Successful retriage replaces the prior review.
            reviews[pr.nodeId]?.priorReview = nil
            persist()
            stageAutoApproveIfEligible(pr: pr, review: aggregated, config: config)
        } catch {
            reviews[pr.nodeId]?.status = .failed(error.localizedDescription)
            liveProgress[pr.nodeId] = nil
            persist()
        }
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

    // MARK: - auto-approve batching

    private func stageAutoApproveIfEligible(
        pr: InboxPR,
        review: AggregatedReview,
        config: RepoConfig
    ) {
        let decision = AutoApprovePolicy.evaluate(
            pr: pr, review: review, config: config.autoApprove
        )
        guard case .approve = decision else { return }
        pendingAutoApprovals[pr.nodeId] = PendingAutoApprove(
            pr: pr, review: review, stagedAt: Date()
        )
        scheduleBatchIfSettled()
    }

    /// Start the undo-window timer iff (a) we have staged approvals and
    /// (b) no review is still in-flight. The "wait until everything is
    /// settled" rule deliberately collapses many notifications into one.
    private func scheduleBatchIfSettled() {
        guard !batchUndoActive else { return }
        guard !pendingAutoApprovals.isEmpty else { return }
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
    func cancelAutoApproveBatch() {
        batchTimer?.cancel()
        batchTimer = nil
        pendingAutoApprovals.removeAll()
        batchUndoActive = false
        batchUndoDeadline = nil
    }

    /// User-pressed "Approve now" — fire immediately instead of waiting.
    func approveBatchNow() {
        batchTimer?.cancel()
        batchTimer = nil
        fireBatch()
    }

    private func fireBatch() {
        let toApprove = Array(pendingAutoApprovals.values)
        pendingAutoApprovals.removeAll()
        batchUndoActive = false
        batchUndoDeadline = nil
        for entry in toApprove {
            let body = "Auto-approved by PRBar (\(formatConfidence(entry.review.confidence)) confidence)."
            Task { [poster = approvePoster] in
                try? await poster(entry.pr, body)
            }
        }
    }

    private func formatConfidence(_ c: Double) -> String {
        String(format: "%.0f%%", c * 100)
    }
}
