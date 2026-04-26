import Foundation
import Observation

/// Routes "this PR is ready for human review" signals into the Notifier
/// according to each repo's `NotifyPolicy`. Replaces the old per-poll
/// `EventDeriver` firing of `.newReviewRequest` events for review-request
/// PRs — those now go through here so we can hold notifications until
/// the AI triage queue settles when the repo asks for batched delivery.
///
/// Inputs:
///   - `track(prs:configResolver:)` — called after each successful poll
///     with the current full inbox. New review-requested PRs are recorded.
///   - `noteReviewSettled(prNodeId:isWorkerSettled:)` — called by
///     `ReviewQueueWorker.onReviewSettled`. Marks the PR as triage-done
///     and, when the worker is fully idle, flushes any held batch.
///
/// Output: `NotificationEvent`s of kind `.newReviewRequest` enqueued on
/// `Notifier`. The Notifier still does its own 60s coalescing window —
/// this coordinator only decides *when* an event is allowed to enter that
/// window in the first place.
@MainActor
@Observable
final class ReadinessCoordinator {
    /// Per-PR readiness state. Lives across polls until the PR drops out
    /// of the inbox (merged / closed / no longer review-requested) — at
    /// which point we forget it so re-requests later behave fresh.
    private struct Tracked: Hashable {
        var pr: InboxPR
        var policy: NotifyPolicy
        /// True once the AI triage has hit a terminal state (or AI was
        /// never enabled for this repo, in which case the PR enters as
        /// already-ready).
        var isReadyForHuman: Bool
        /// True once we've fired a notification for this PR. Prevents
        /// re-notifying on subsequent polls / re-runs.
        var hasNotified: Bool
    }

    private var tracked: [String: Tracked] = [:]

    @ObservationIgnored
    private weak var notifier: Notifier?

    init(notifier: Notifier? = nil) {
        self.notifier = notifier
    }

    func setNotifier(_ n: Notifier) {
        self.notifier = n
    }

    /// Take a fresh inbox snapshot. Adds new review-requested PRs to
    /// `tracked`, drops PRs that have left the inbox, and flushes any
    /// `.eachReady` PRs that are already-ready (e.g. `aiReviewEnabled`
    /// was off so they entered ready immediately).
    func track(
        prs: [InboxPR],
        configResolver: (_ owner: String, _ repo: String) -> RepoConfig
    ) {
        let inboxIds = Set(prs.map(\.nodeId))
        // Forget PRs no longer in the inbox.
        for id in tracked.keys where !inboxIds.contains(id) {
            tracked.removeValue(forKey: id)
        }

        for pr in prs where pr.role == .reviewRequested || pr.role == .both {
            // Skip drafts unless the repo opts in — mirrors worker policy.
            let cfg = configResolver(pr.owner, pr.repo)
            if pr.isDraft && !cfg.reviewDrafts { continue }

            if tracked[pr.nodeId] == nil {
                // First time we see this PR in review-requested state.
                // If the repo has AI disabled, it's ready for human now;
                // otherwise wait for the worker callback.
                tracked[pr.nodeId] = Tracked(
                    pr: pr,
                    policy: cfg.notifyPolicy,
                    isReadyForHuman: !cfg.aiReviewEnabled,
                    hasNotified: false
                )
            } else {
                // Keep the latest PR snapshot (title/state may have moved).
                tracked[pr.nodeId]?.pr = pr
                tracked[pr.nodeId]?.policy = cfg.notifyPolicy
            }
        }

        // `.eachReady` PRs that became ready (e.g. AI just disabled, or a
        // newly-added PR with AI off) flush immediately.
        flushEachReady()
    }

    /// Called when the worker finishes a review. Marks the PR ready and,
    /// if the worker is fully settled, flushes any batched repos.
    func noteReviewSettled(prNodeId: String, isWorkerSettled: Bool) {
        if tracked[prNodeId] != nil {
            tracked[prNodeId]?.isReadyForHuman = true
        }
        // Always flush per-ready PRs (cheap; no-op when none queued).
        flushEachReady()
        if isWorkerSettled {
            flushBatchSettled()
        }
    }

    /// Fire and mark notified for any `.eachReady` repo whose PR is ready.
    private func flushEachReady() {
        let toFire = tracked.values.filter {
            $0.policy == .eachReady && $0.isReadyForHuman && !$0.hasNotified
        }
        guard !toFire.isEmpty, let notifier else { return }
        let events = toFire.map { Self.event(for: $0.pr) }
        notifier.enqueue(events)
        for entry in toFire {
            tracked[entry.pr.nodeId]?.hasNotified = true
        }
    }

    /// Fire one grouped notification for every `.batchSettled` PR that's
    /// ready and not yet notified. Called only when the worker idles.
    private func flushBatchSettled() {
        let toFire = tracked.values.filter {
            $0.policy == .batchSettled && $0.isReadyForHuman && !$0.hasNotified
        }
        guard !toFire.isEmpty, let notifier else { return }
        let events = toFire.map { Self.event(for: $0.pr) }
        notifier.enqueue(events)
        for entry in toFire {
            tracked[entry.pr.nodeId]?.hasNotified = true
        }
    }

    private static func event(for pr: InboxPR) -> NotificationEvent {
        NotificationEvent(
            kind: .newReviewRequest,
            prNodeId: pr.nodeId,
            prTitle: pr.title,
            prRepo: pr.nameWithOwner,
            prNumber: pr.number,
            prURL: pr.url
        )
    }
}
