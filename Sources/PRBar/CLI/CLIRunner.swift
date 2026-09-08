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
    let client: GHClient

    struct Outcome {
        var isFailure: Bool
        var note: String
        var costUsd: Double?
        var sessionId: String?
        /// The provider that actually ran, which a repo rule can change
        /// out from under the configured default.
        var providerId: ProviderID?
    }

    func review(pr: InboxPR, force: Bool, providerOverride: ProviderID?) async -> Outcome {
        let posts = PostRecorder()
        let worker = ReviewQueueWorker(
            diffFetcher: { [client] owner, repo, number in
                try await client.fetchDiff(owner: owner, repo: repo, number: number)
            },
            checkoutManager: RepoCheckoutManager(),
            cache: nil,
            failureLogStore: nil
        )
        worker.configResolver = config.resolver()
        worker.defaultProviderId = config.defaultProvider
        if let v = config.defaultClaudeModel { worker.defaultClaudeModel = v }
        if let v = config.defaultClaudeEffort { worker.defaultClaudeEffort = v }
        if let v = config.defaultCodexModel { worker.defaultCodexModel = v }
        if let v = config.defaultCodexEffort { worker.defaultCodexEffort = v }
        worker.reviewThreadFetcher = { [client] owner, repo, number in
            try await client.fetchReviewThreads(owner: owner, repo: repo, number: number)
        }
        // No human is watching a banner, so the staged batch fires as soon
        // as the run settles.
        worker.undoWindow = 0
        worker.actionLog = posts

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
            worker.enqueueNewReviewRequests(from: [pr])
        }

        // Nothing was queued at all — a gate rejected it synchronously, or
        // the PR is not one this viewer was asked to review.
        guard worker.reviews[pr.nodeId] != nil else {
            return Outcome(
                isFailure: false,
                note: "not reviewed: no review request for the authenticated user "
                    + "(pass --force to review anyway)")
        }

        await settled.wait()

        // A staged post fires on its own timer; wait for the action log to
        // confirm it landed rather than exiting mid-write.
        if worker.pendingAutoActions[pr.nodeId] != nil || worker.batchUndoActive {
            await posts.wait()
        }

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
            if let post = posts.entries.first {
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
            let failed = posts.entries.first?.outcome == .failure
            return Outcome(isFailure: failed, note: parts.joined(separator: "; "),
                           costUsd: nonZero(review.costUsd), providerId: state.providerId)
        }
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

/// Captures the worker's auto-review action-log writes, which double as
/// the "post finished" signal.
@MainActor
final class PostRecorder: ActionLogging {
    struct Entry {
        let kind: ActionLogKind
        let outcome: ActionLogOutcome
        let errorMessage: String?
        let costUsd: Double?
    }

    private(set) var entries: [Entry] = []
    private let waiter = Waiter()

    func wait() async { await waiter.wait() }

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
        waiter.signal()
    }
}
