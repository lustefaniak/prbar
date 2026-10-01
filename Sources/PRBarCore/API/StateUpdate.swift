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
    /// Parsed diffs and CI log tails, per `DiffStore.key` /
    /// `FailureLogStore.key`, only those someone asked for and only the
    /// ones that changed: a diff can be megabytes.
    var diffs: [String: DiffStore.LoadStatus]?
    var removedDiffs: [String]?
    var ciLogs: [String: FailureLogStore.LoadStatus]?
    var removedCILogs: [String]?
    var config: ConfigState?
    var actionLog: LogUpdate<ActionRecord>?
    var reviewLog: LogUpdate<ReviewRecord>?
    var historyImport: HistoryImportState?

    var isEmpty: Bool {
        prs == nil && polling == nil && reviews == nil && removedReviews == nil
            && progress == nil && autoReview == nil && actions == nil
            && diffs == nil && removedDiffs == nil && ciLogs == nil && removedCILogs == nil
            && config == nil && actionLog == nil && reviewLog == nil && historyImport == nil
    }
}

/// A history log, newest first. Records are only ever added at the front,
/// so a change is usually `added`; anything else (a reload after the
/// import, a clear, retention) resends the whole log as `reset`.
struct LogUpdate<Record: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    var reset: [Record]?
    var added: [Record]?

    /// What turns `old` into `new`.
    static func between(_ old: [Record], _ new: [Record]) -> LogUpdate {
        let extra = new.count - old.count
        if extra > 0, new.dropFirst(extra).elementsEqual(old) {
            return LogUpdate(added: Array(new.prefix(extra)))
        }
        return LogUpdate(reset: new)
    }

    func applied(to records: [Record]) -> [Record] {
        if let reset { return reset }
        return (added ?? []) + records
    }
}

/// The one-time import of history from before v0.15.0.
struct HistoryImportState: Codable, Sendable, Equatable {
    var actions: HistoryImportStatus?
    var reviews: HistoryImportStatus?
}

/// `prbar.yaml` as the server has it in effect, and what's wrong with it.
struct ConfigState: Codable, Sendable, Equatable {
    var config: PRBarConfig
    /// `RepoConfigStore.revision`: higher is newer.
    var revision: Int
    var path: String
    var loadIssue: String?
    var warnings: [String]
    var migratedFromLegacy: Bool
    /// The rules directory doesn't compile. Nil from an older server.
    var rulesIssue: String? = nil
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
