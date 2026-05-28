import Foundation
import Observation
import OSLog

/// What a queued GitHub write does. Captured by value so a failed
/// action can be retried verbatim without the UI reconstructing it.
enum GHActionKind: Sendable, Equatable {
    case review(kind: ReviewActionKind, body: String, comments: [GHClient.InlineComment])
    case merge(method: MergeMethod)
}

/// Where an action originated. Drives which `ActionLogKind` is recorded
/// and whether cost is logged (auto-approve carries the AI cost).
enum ActionSource: Sendable, Equatable {
    case manual
    case autoApprove
}

/// One captured GitHub write, fully self-describing so the queue can run
/// or re-run it on its own. `attempts` increments on each retry.
struct GHAction: Sendable, Identifiable, Equatable {
    let id: UUID
    let pr: InboxPR
    let kind: GHActionKind
    let source: ActionSource
    /// AI cost to log for auto-approve entries; nil for manual writes.
    let costUsd: Double?
    let enqueuedAt: Date
    var attempts: Int

    init(
        id: UUID = UUID(),
        pr: InboxPR,
        kind: GHActionKind,
        source: ActionSource = .manual,
        costUsd: Double? = nil,
        enqueuedAt: Date = Date(),
        attempts: Int = 0
    ) {
        self.id = id
        self.pr = pr
        self.kind = kind
        self.source = source
        self.costUsd = costUsd
        self.enqueuedAt = enqueuedAt
        self.attempts = attempts
    }
}

/// Lifecycle of a queued action as the UI sees it. Terminal success
/// removes the entry entirely; `.failed` is retained so the user can
/// retry or dismiss.
enum ActionRunState: Sendable, Equatable {
    case queued
    case running
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .queued, .running: return true
        case .failed: return false
        }
    }
}

struct ActionEntry: Sendable, Equatable {
    var action: GHAction
    var state: ActionRunState
}

/// Serialized queue for GitHub *write* operations (post review, merge,
/// auto-approve). Mirrors `ReviewQueueWorker`'s drain pattern: a `pending`
/// list, a bounded set of in-flight runners, and `drainIfPossible`.
///
/// Two guarantees the UI relies on:
/// - **Per-PR single slot.** At most one entry per `pr.nodeId` exists at a
///   time; a second `enqueue` while one is queued/running is a no-op. This
///   is the accidental-double-submit guard — a slow `gh` can't be
///   double-fired by an impatient second click.
/// - **Per-PR serialization, cross-PR parallelism.** `maxConcurrent`
///   runners drain the queue, but a node already in flight is never picked
///   again until it settles, so two writes to the same PR can't race.
@MainActor
@Observable
final class ActionQueue {
    /// Observable per-PR state keyed by `pr.nodeId`. Cleared on success,
    /// retained as `.failed` on error. Drives button-disable + the inbox
    /// row indicator.
    private(set) var entries: [String: ActionEntry] = [:]

    /// Hard cap on concurrent runners. Per-PR serialization is enforced
    /// separately via `inFlightNodes`, so this only bounds how many
    /// *different* PRs run at once.
    var maxConcurrent: Int = 2

    @ObservationIgnored
    private var pending: [GHAction] = []

    @ObservationIgnored
    private var inFlightNodes: Set<String> = []

    /// Posts a review (with or without inline comments). Injected so tests
    /// don't shell out. Non-empty `comments` should use the richer
    /// `postReviewWithComments` path; empty falls back to `postReview`.
    @ObservationIgnored
    var reviewExecutor: @Sendable (
        _ pr: InboxPR, _ kind: ReviewActionKind, _ body: String,
        _ comments: [GHClient.InlineComment]
    ) async throws -> Void = { _, _, _, _ in }

    /// Merges a PR. Injected so tests don't shell out.
    @ObservationIgnored
    var mergeExecutor: @Sendable (_ pr: InboxPR, _ method: MergeMethod) async throws -> Void = { _, _ in }

    /// Action history sink — one entry per attempt (success and failure).
    @ObservationIgnored
    weak var actionLog: ActionLogStore?

    /// Fired on the main actor after a successful write so the caller can
    /// refresh the PR (the GraphQL read-model lags `gh` REST writes — wire
    /// this to a refresh-now + delayed-forced-refresh).
    @ObservationIgnored
    var onActionCompleted: (@MainActor (_ pr: InboxPR) -> Void)?

    init() {}

    /// Real `GHClient`-backed queue. Mirrors the executor closures
    /// `PRPoller.live` used to carry before writes moved here.
    static func live() -> ActionQueue {
        let client: GHClient? = try? GHClient()
        let q = ActionQueue()
        q.reviewExecutor = { pr, kind, body, comments in
            let c = try client ?? GHClient()
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
        q.mergeExecutor = { pr, method in
            let c = try client ?? GHClient()
            try await c.mergePR(
                owner: pr.owner, repo: pr.repo, number: pr.number,
                method: method, deleteBranch: false
            )
        }
        return q
    }

    // MARK: - public API

    func state(for nodeId: String) -> ActionRunState? {
        entries[nodeId]?.state
    }

    /// True while an action for this PR is queued or running (the UI
    /// disables its trigger control on this).
    func isBusy(_ nodeId: String) -> Bool {
        entries[nodeId]?.state.isBusy ?? false
    }

    /// Enqueue a write. No-op if one is already queued/running for this PR
    /// (the double-submit guard). A `.failed` entry is replaced. Merge to a
    /// disallowed method fails immediately without enqueuing.
    func enqueue(
        _ pr: InboxPR,
        kind: GHActionKind,
        source: ActionSource = .manual,
        costUsd: Double? = nil
    ) {
        let nodeId = pr.nodeId
        if let existing = entries[nodeId]?.state, existing.isBusy {
            PRBarLog.actions.debug("enqueue skip reason=in-flight pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public)")
            return
        }
        if case .merge(let method) = kind, !pr.allowedMergeMethods.contains(method) {
            let msg = "\(method.displayName) is disabled on \(pr.nameWithOwner)."
            let action = GHAction(pr: pr, kind: kind, source: source, costUsd: costUsd)
            entries[nodeId] = ActionEntry(action: action, state: .failed(msg))
            PRBarLog.actions.notice("enqueue refused reason=disallowed-merge pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public) method=\(method.rawValue, privacy: .public)")
            return
        }
        let action = GHAction(pr: pr, kind: kind, source: source, costUsd: costUsd)
        entries[nodeId] = ActionEntry(action: action, state: .queued)
        pending.append(action)
        PRBarLog.actions.notice("enqueue pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public) kind=\(Self.label(kind), privacy: .public) source=\(String(describing: source), privacy: .public)")
        drainIfPossible()
    }

    /// Re-run a failed action verbatim (same captured parameters).
    func retry(_ nodeId: String) {
        guard let entry = entries[nodeId], case .failed = entry.state else { return }
        var action = entry.action
        action.attempts += 1
        entries[nodeId] = ActionEntry(action: action, state: .queued)
        pending.append(action)
        PRBarLog.actions.notice("retry pr=\(entry.action.pr.nameWithOwner, privacy: .public)#\(entry.action.pr.number, privacy: .public) attempt=\(action.attempts, privacy: .public)")
        drainIfPossible()
    }

    /// Drop a failed entry the user has given up on (or acknowledged).
    func dismissFailure(_ nodeId: String) {
        guard let entry = entries[nodeId], case .failed = entry.state else { return }
        entries[nodeId] = nil
    }

    // MARK: - draining

    private func drainIfPossible() {
        while inFlightNodes.count < maxConcurrent {
            // Pick the oldest pending action whose PR isn't already in
            // flight — that's the per-PR serialization rule.
            guard let idx = pending.firstIndex(where: { !inFlightNodes.contains($0.pr.nodeId) }) else {
                return
            }
            let action = pending.remove(at: idx)
            inFlightNodes.insert(action.pr.nodeId)
            entries[action.pr.nodeId]?.state = .running
            Task { await self.run(action) }
        }
    }

    private func run(_ action: GHAction) async {
        let pr = action.pr
        let nodeId = pr.nodeId
        defer {
            inFlightNodes.remove(nodeId)
            drainIfPossible()
        }
        do {
            switch action.kind {
            case .review(let kind, let body, let comments):
                try await reviewExecutor(pr, kind, body, comments)
                recordSuccess(action)
            case .merge(let method):
                try await mergeExecutor(pr, method)
                recordSuccess(action)
            }
            // Terminal success: drop the slot and let the caller refresh.
            entries[nodeId] = nil
            onActionCompleted?(pr)
        } catch {
            let msg = error.localizedDescription
            entries[nodeId]?.state = .failed(msg)
            recordFailure(action, message: msg)
            PRBarLog.actions.error("run failed pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public) error=\(msg, privacy: .public)")
        }
    }

    // MARK: - logging

    private func recordSuccess(_ action: GHAction) {
        let (kind, detail) = Self.logKindAndDetail(action)
        actionLog?.record(
            kind: kind, outcome: .success, pr: action.pr,
            detail: detail,
            headSha: action.source == .autoApprove ? action.pr.headSha : nil,
            costUsd: action.costUsd
        )
    }

    private func recordFailure(_ action: GHAction, message: String) {
        let (kind, detail) = Self.logKindAndDetail(action)
        actionLog?.record(
            kind: kind, outcome: .failure, pr: action.pr,
            errorMessage: message, detail: detail,
            headSha: action.source == .autoApprove ? action.pr.headSha : nil,
            costUsd: action.costUsd
        )
    }

    private static func logKindAndDetail(_ action: GHAction) -> (ActionLogKind, String?) {
        switch action.kind {
        case .review(let kind, let body, _):
            let logKind: ActionLogKind = action.source == .autoApprove ? .autoApprove : kind.actionLogKind
            return (logKind, body.isEmpty ? nil : body)
        case .merge(let method):
            return (.merge, method.rawValue)
        }
    }

    private static func label(_ kind: GHActionKind) -> String {
        switch kind {
        case .review(let k, _, _): return "review(\(k.rawValue))"
        case .merge(let m): return "merge(\(m.rawValue))"
        }
    }
}
