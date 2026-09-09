import Foundation

/// Drives one `ReviewQueueWorker` run to completion.
///
/// Everything the app persists is left nil: no review cache (a fresh
/// process has no prior state to reuse), no CI-failure store, and no
/// review log — which also means the app's daily cost cap is inert here,
/// deliberately, because brahmanda's rolling budgets own spend. The one
/// sink that *is* wired is the action log, because the worker records one
/// entry there per posted auto-review and that is precisely the "the post
/// landed" signal this process needs before it exits.
@MainActor
struct Runner {
    let config: CLIConfig

    /// Injected rather than taking a `GHClient`, which cannot be
    /// constructed without `gh` on PATH — the skip paths reach neither
    /// fetch, and that is exactly what needs testing.
    var diffFetcher: @Sendable (_ owner: String, _ repo: String, _ number: Int) async throws -> String
    var reviewThreadFetcher: @Sendable (_ owner: String, _ repo: String, _ number: Int) async throws -> ReviewThreadPage
    /// Posts the staged auto-review. Injected for the same reason as the
    /// fetches — a test must be able to drive the post path without `gh`.
    var reviewPoster: @Sendable (
        _ pr: InboxPR, _ kind: ReviewActionKind, _ body: String,
        _ comments: [GHClient.InlineComment]
    ) async throws -> Void = { _, _, _, _ in }
    /// Restores the review request a verdict-less share consumed.
    var reviewerRequester: @Sendable (_ pr: InboxPR, _ login: String) async throws -> Void = { _, _ in }
    /// Closes review threads the triage decided are addressed.
    var threadResolver: @Sendable (_ threadId: String) async throws -> Void = { _ in }

    /// Test seam. Nil uses the real claude/codex providers, which is the
    /// only thing a production run wants — but it means a test that reaches
    /// the review path spawns a paid CLI call, so tests set this.
    var provider: (any ReviewProvider)?

    struct Outcome {
        var isFailure: Bool
        var note: String
        var costUsd: Double?
        var sessionId: String?
        /// The provider that actually ran, which a repo rule can change
        /// out from under the configured default.
        var providerId: ProviderID?
        /// The completed review, so the caller can emit it. Nil for a
        /// skip or a failure — there is nothing to report.
        var review: AggregatedReview?
        /// Whether a verdict or share actually landed on the PR.
        var posted: Bool = false
    }

    func review(pr: InboxPR, force: Bool, providerOverride: ProviderID?) async -> Outcome {
        let posts = PostRecorder()
        let worker = ReviewQueueWorker(
            diffFetcher: diffFetcher,
            checkoutManager: RepoCheckoutManager(),
            cache: nil,
            failureLogStore: nil
        )
        if let provider {
            // `providerLookup` wins in the run path, so both have to go —
            // otherwise a test still spawns a real, paid claude call.
            worker.provider = provider
            worker.providerLookup = { _ in provider }
        }
        worker.configResolver = config.resolver()
        worker.defaultProviderId = config.defaultProvider
        if let v = config.defaultClaudeModel { worker.defaultClaudeModel = v }
        if let v = config.defaultClaudeEffort { worker.defaultClaudeEffort = v }
        if let v = config.defaultCodexModel { worker.defaultCodexModel = v }
        if let v = config.defaultCodexEffort { worker.defaultCodexEffort = v }
        worker.reviewThreadFetcher = reviewThreadFetcher
        // No human is watching a banner, so the staged batch fires as soon
        // as the run settles.
        worker.undoWindow = 0
        worker.actionLog = posts

        // Own the post rather than letting `fireBatch` fall through to its
        // built-in poster. Two things depend on it:
        //
        // - **The verdict marker.** The app appends it in `ActionQueue`,
        //   which is app-only and excluded from PRBarCore. Without this the
        //   CLI's posts carry no `prbar:verdict` marker, so every other
        //   PRBar instance re-reviews and re-posts the same head SHA —
        //   exactly the duplicate cost the marker exists to prevent.
        // - **The exit race.** `fireBatch` clears its staging flags *before*
        //   spawning the post, so a runner checking those flags could see
        //   them already false and exit mid-write. Registering the post
        //   here happens synchronously inside `fireBatch`, before it
        //   returns, so the wait below cannot miss it.
        worker.enqueueAutoReview = { [reviewPoster, reviewerRequester] pr, kind, body, comments, cost, source in
            posts.expect()
            Task { @MainActor in
                let outgoing = source.isAutomated
                    ? PRBarVerdictMarker.append(to: body, sha: pr.headSha)
                    : body
                do {
                    try await reviewPoster(pr, kind, outgoing, comments)
                    posts.record(kind: Self.logKind(kind, source), outcome: .success,
                                 pr: pr, errorMessage: nil, detail: nil,
                                 headSha: pr.headSha, costUsd: cost, timestamp: Date())
                    // A share casts no verdict, but GitHub drops the viewer
                    // from reviewRequests anyway — so without this the PR
                    // leaves the inbox and is never retriaged.
                    if source == .sharedFindings, !pr.viewerLogin.isEmpty {
                        do {
                            try await reviewerRequester(pr, pr.viewerLogin)
                            posts.record(kind: .reviewReRequested, outcome: .success,
                                         pr: pr, errorMessage: nil, detail: nil,
                                         headSha: pr.headSha, costUsd: nil, timestamp: Date())
                        } catch {
                            posts.record(kind: .reviewReRequested, outcome: .failure,
                                         pr: pr, errorMessage: error.localizedDescription,
                                         detail: nil, headSha: pr.headSha, costUsd: nil,
                                         timestamp: Date())
                        }
                    }
                } catch {
                    posts.record(kind: Self.logKind(kind, source), outcome: .failure,
                                 pr: pr, errorMessage: error.localizedDescription, detail: nil,
                                 headSha: pr.headSha, costUsd: cost, timestamp: Date())
                }
                posts.finish()
            }
        }
        // Resolving addressed threads is opt-in and was wired to nothing,
        // so the worker logged "thread resolve queued" and dropped it.
        worker.enqueueResolveThreads = { [threadResolver] pr, threadIds in
            posts.expect()
            Task { @MainActor in
                var failure: String?
                for id in threadIds {
                    do { try await threadResolver(id) }
                    catch { failure = error.localizedDescription }
                }
                posts.record(kind: .autoResolveThreads,
                             outcome: failure == nil ? .success : .failure,
                             pr: pr, errorMessage: failure, detail: "\(threadIds.count) thread(s)",
                             headSha: pr.headSha, costUsd: nil, timestamp: Date())
                posts.finish()
            }
        }

        let settled = Waiter()
        worker.onReviewSettled = { nodeId, _ in
            guard nodeId == pr.nodeId else { return }
            settled.signal()
        }

        if force {
            worker.enqueue(pr, force: true, providerOverride: providerOverride)
        } else {
            // Not `enqueue`: this applies the repo gates (AI off, draft,
            // already reviewed by a human, an AI verdict already posted at
            // this SHA) and records a typed skip reason for each.
            worker.enqueueNewReviewRequests(from: [pr], providerOverride: providerOverride)
        }

        // Nothing was recorded at all: `enqueue` drops an excluded repo
        // without a trace, and `enqueueNewReviewRequests` ignores a PR
        // this viewer was not asked to review.
        guard let queued = worker.reviews[pr.nodeId] else {
            if config.resolver()(pr.owner, pr.repo).excluded {
                return Outcome(
                    isFailure: false,
                    note: "not reviewed: \(pr.owner)/\(pr.repo) is excluded by config")
            }
            return Outcome(
                isFailure: false,
                note: "not reviewed: no review request for the authenticated user "
                    + "(pass --force to review anyway)")
        }

        // A gate that rejected the PR synchronously recorded a terminal
        // state without firing `onReviewSettled` — only the cache-hit
        // branch and the end of a real triage do that — so waiting on the
        // settle signal here would never return.
        if !queued.status.isTerminal {
            await settled.wait()
        }

        // A staged post fires on its own timer, so there are two waits and
        // the order matters.
        //
        // Staging happens synchronously during the triage, before the
        // settle signal, so a post that is coming is already visible here.
        // `fireBatch` then clears these flags and registers the post in the
        // same synchronous block — so once they are clear, `posts` knows
        // about the write. Draining first would race that and exit before
        // the batch had even fired.
        while worker.pendingAutoActions[pr.nodeId] != nil || worker.batchUndoActive {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        await posts.drain()

        return outcome(state: worker.reviews[pr.nodeId], posts: posts, worker: worker, pr: pr)
    }

    private func outcome(
        state: ReviewState?, posts: PostRecorder, worker: ReviewQueueWorker, pr: InboxPR
    ) -> Outcome {
        guard let state else {
            return Outcome(isFailure: true, note: "review state vanished")
        }
        switch state.status {
        case let .skipped(reason):
            return Outcome(isFailure: false, note: "skipped: \(reason.short)")
        case let .failed(message):
            return Outcome(isFailure: true, note: message, costUsd: nonZero(state.costUsd),
                           providerId: state.providerId)
        case .queued, .running:
            return Outcome(isFailure: true, note: "still running at exit",
                           costUsd: nonZero(state.costUsd), providerId: state.providerId)
        case let .completed(review):
            var parts = ["\(review.verdict.rawValue) (confidence \(pct(review.confidence)))"]
            parts.append("\(review.annotations.count) findings")
            if let post = posts.reviewEntry {
                parts.append(post.outcome == .success
                    ? "posted \(post.kind.rawValue)"
                    : "post failed: \(post.errorMessage ?? "unknown")")
            } else if worker.flaggedDenials[pr.nodeId] != nil {
                parts.append("flagged, nothing posted")
            } else {
                parts.append("nothing posted (no gate fired)")
            }
            if review.isSubscriptionAuth {
                parts.append("cost is API-equivalent (subscription auth)")
            }
            let failed = posts.reviewEntry?.outcome == .failure
            return Outcome(isFailure: failed, note: parts.joined(separator: "; "),
                           costUsd: nonZero(review.costUsd), providerId: state.providerId,
                           review: review,
                           posted: posts.reviewEntry?.outcome == .success)
        }
    }

    /// Mirrors `ActionQueue.logKindAndDetail` — a share and an auto-deny
    /// `.comment` post the identical GitHub event, so the source is the only
    /// thing that tells them apart in a History query.
    private static func logKind(_ action: ReviewActionKind, _ source: ActionSource) -> ActionLogKind {
        source == .sharedFindings ? .autoShare : action.autoActionLogKind
    }

    private func nonZero(_ v: Double) -> Double? { v > 0 ? v : nil }

    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
}

/// One-shot await that tolerates being signalled before anyone waits.
@MainActor
final class Waiter {
    private var fired = false
    private var continuation: CheckedContinuation<Void, Never>?

    func signal() {
        fired = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        guard !fired else { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

/// Tracks the writes this process still owes GitHub.
///
/// `expect()` is called synchronously from inside `fireBatch`, before it
/// returns, so a post can never be registered *after* the runner has
/// decided nothing is pending — which is how the previous check against
/// the worker's staging flags could exit mid-write.
@MainActor
final class PostRecorder: ActionLogging {
    struct Entry {
        let kind: ActionLogKind
        let outcome: ActionLogOutcome
        let errorMessage: String?
        let costUsd: Double?
    }

    private(set) var entries: [Entry] = []
    private var outstanding = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// A write is about to start.
    func expect() { outstanding += 1 }

    /// A write finished, successfully or not.
    func finish() {
        outstanding = max(0, outstanding - 1)
        guard outstanding == 0 else { return }
        let pending = waiters
        waiters = []
        for w in pending { w.resume() }
    }

    /// Wait until nothing is outstanding. Returns immediately when the run
    /// posted nothing at all, which is the common case.
    func drain() async {
        guard outstanding > 0 else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// The first *review* post, which is what the outcome line reports.
    /// Re-request and thread-resolve rows are bookkeeping around it.
    var reviewEntry: Entry? {
        entries.first { $0.kind != .reviewReRequested && $0.kind != .autoResolveThreads }
    }

    func record(
        kind: ActionLogKind,
        outcome: ActionLogOutcome,
        pr _: InboxPR,
        errorMessage: String?,
        detail _: String?,
        headSha _: String?,
        costUsd: Double?,
        timestamp _: Date
    ) {
        entries.append(Entry(kind: kind, outcome: outcome,
                             errorMessage: errorMessage, costUsd: costUsd))
    }
}
