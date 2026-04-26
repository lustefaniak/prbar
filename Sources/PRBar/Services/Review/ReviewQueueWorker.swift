import Foundation
import Observation

/// One pending or completed AI review keyed by PR node ID. Drives the
/// per-row "review status" UI in the inbox and the AI section in the
/// detail pane.
struct ReviewState: Sendable, Hashable {
    enum Status: Sendable, Hashable {
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
    let triggeredAt: Date
    var status: Status
    /// Cost spent on this review (sum across subreviews after completion;
    /// 0 while running).
    var costUsd: Double
}

/// Actor (well, @MainActor @Observable class) that drains a queue of
/// pending PR reviews. Auto-enqueues incoming review requests; can be
/// triggered manually for re-runs. Concurrency-bounded.
@MainActor
@Observable
final class ReviewQueueWorker {
    private(set) var reviews: [String: ReviewState] = [:]

    /// Hard cap on parallel reviews. Each review is one or more provider
    /// calls (one per Subdiff); 2 concurrent calls = ~$0.40 burst at the
    /// minimal-tools rates.
    var maxConcurrent: Int = 2

    /// Daily spend ceiling. Computed from the total of all completed
    /// reviews today (not a real running daily-window — for now we cap
    /// the cumulative since process start, which is good enough for a
    /// menu-bar app that gets restarted often).
    var dailyCostCap: Double = 5.0

    /// AI provider. Pluggable; v1 ships `ClaudeProvider`.
    @ObservationIgnored
    var provider: ReviewProvider = ClaudeProvider()

    /// What tool-access mode the provider runs in.
    var toolMode: ToolMode = .none

    /// Closure that fetches the unified diff for a PR. Injected so tests
    /// don't need a real `gh` install.
    @ObservationIgnored
    var diffFetcher: @Sendable (_ owner: String, _ repo: String, _ number: Int) async throws -> String

    /// On-disk checkout manager. Used in `.minimal` tool mode to give the
    /// AI a real workdir for `Read`/`Grep`. Nil → fall back to empty temp
    /// dirs (which only makes sense in `.none` mode anyway).
    @ObservationIgnored
    var checkoutManager: RepoCheckoutManager?

    @ObservationIgnored
    private var inFlight: Int = 0

    @ObservationIgnored
    private var pending: [InboxPR] = []

    init(
        diffFetcher: @escaping @Sendable (_ owner: String, _ repo: String, _ number: Int) async throws -> String,
        checkoutManager: RepoCheckoutManager? = nil
    ) {
        self.diffFetcher = diffFetcher
        self.checkoutManager = checkoutManager
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
            checkoutManager: checkout
        )
    }

    /// Enqueue a PR for review. Idempotent — already-known PR is a no-op
    /// unless `force = true` (re-run).
    func enqueue(_ pr: InboxPR, force: Bool = false) {
        if !force, let existing = reviews[pr.nodeId], !existing.status.isTerminal {
            return
        }
        if !force, case .completed = reviews[pr.nodeId]?.status {
            return
        }
        if cumulativeSpend() >= dailyCostCap {
            reviews[pr.nodeId] = ReviewState(
                prNodeId: pr.nodeId,
                triggeredAt: Date(),
                status: .failed("Daily $\(String(format: "%.2f", dailyCostCap)) cap reached."),
                costUsd: 0
            )
            return
        }
        reviews[pr.nodeId] = ReviewState(
            prNodeId: pr.nodeId,
            triggeredAt: Date(),
            status: .queued,
            costUsd: 0
        )
        pending.append(pr)
        drainIfPossible()
    }

    /// Auto-enqueue any review-requested PR we haven't seen before. Wired
    /// from `PRPoller` after each successful poll. Intentionally idempotent
    /// — repeat polls are no-ops.
    func enqueueNewReviewRequests(from prs: [InboxPR]) {
        for pr in prs where pr.role == .reviewRequested || pr.role == .both {
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
            Task { await self.run(pr: next) }
        }
    }

    private func run(pr: InboxPR) async {
        defer {
            inFlight -= 1
            drainIfPossible()
        }

        reviews[pr.nodeId]?.status = .running

        do {
            let diffText = try await diffFetcher(pr.owner, pr.repo, pr.number)
            let config = MonorepoConfig.match(owner: pr.owner, repo: pr.repo)
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

            var outcomes: [SubreviewOutcome] = []
            for subdiff in subdiffs {
                let workdir = resolveWorkdir(handle: sharedHandle, subpath: subdiff.subpath)
                let bundle = try ContextAssembler.assemble(
                    pr: pr,
                    subdiff: subdiff,
                    diffText: diffText,
                    toolMode: effectiveToolMode,
                    workdir: workdir
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
                let result = try await provider.review(bundle: bundle, options: options)
                outcomes.append(SubreviewOutcome(subpath: subdiff.subpath, result: result))
            }

            guard let aggregated = ResultAggregator.aggregate(outcomes) else {
                reviews[pr.nodeId]?.status = .failed("No subreviews aggregated.")
                return
            }
            reviews[pr.nodeId]?.status = .completed(aggregated)
            reviews[pr.nodeId]?.costUsd = aggregated.costUsd
        } catch {
            reviews[pr.nodeId]?.status = .failed(error.localizedDescription)
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
}
