import Foundation
import Observation

/// What a front end renders, sent by the server as it changes. Every
/// section is optional: an update carries only the sections that changed,
/// and a snapshot (the reply to `subscribe` with `state: true`) carries all
/// of them.
///
/// Sections are split by how often they change and how big they are: the
/// PR list is ~100 KB and changes once a poll, while `polling` flips twice
/// a poll and is tiny.
struct StateUpdate: Codable, Sendable, Equatable {
    var prs: [InboxPR]?
    var polling: PollingState?
    /// Per PR, only the ones that changed: a completed review carries its
    /// whole result, so resending all of them on every change would not do.
    var reviews: [String: ReviewState]?
    var removedReviews: [String]?
    /// Reviews in flight; small, and replaced whole.
    var progress: [String: ReviewProgress]?
    var autoReview: AutoReviewState?
    var actions: ActionQueueState?

    var isEmpty: Bool {
        prs == nil && polling == nil && reviews == nil && removedReviews == nil
            && progress == nil && autoReview == nil && actions == nil
    }
}

/// GitHub writes queued, running, retrying or failed, per PR, and the ones
/// that just succeeded (for the confirmation flash).
struct ActionQueueState: Codable, Sendable, Equatable {
    var entries: [String: ActionEntry]
    var recentSuccess: [String: GHActionKind]
}

/// Auto reviews staged behind the undo window, and denials flagged for the
/// user instead of posted.
struct AutoReviewState: Codable, Sendable, Equatable {
    var pending: [String: ReviewQueueWorker.StagedAutoReview]
    var flagged: [String: ReviewQueueWorker.StagedAutoReview]
    var batchUndoActive: Bool
    var batchUndoDeadline: Date?
}

struct PollingState: Codable, Sendable, Equatable {
    var lastFetchedAt: Date?
    var lastError: String?
    var isFetching: Bool
    /// PRs being refreshed one by one, for the per-row spinner.
    var refreshingPRs: Set<String>
}

/// Calls `onChange` with a fresh value whenever what `read` reads changes,
/// using Observation, so the runtime's services need no hooks of their
/// own. Changes made in one main-actor turn arrive as one call.
@MainActor
final class StateTracker<Value: Equatable> {
    private let read: @MainActor () -> Value
    private let onChange: @MainActor (Value) -> Void
    private var last: Value?
    private var isStopped = false

    init(read: @escaping @MainActor () -> Value, onChange: @escaping @MainActor (Value) -> Void) {
        self.read = read
        self.onChange = onChange
        last = observe()
    }

    var current: Value { last ?? read() }

    func stop() {
        isStopped = true
    }

    private func observe() -> Value {
        withObservationTracking {
            read()
        } onChange: { [weak self] in
            Task { @MainActor in self?.changed() }
        }
    }

    private func changed() {
        guard !isStopped else { return }
        let value = observe()
        guard value != last else { return }
        last = value
        onChange(value)
    }
}
