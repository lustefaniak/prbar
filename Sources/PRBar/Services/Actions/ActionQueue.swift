import Foundation
import Observation
import OSLog

/// What a queued GitHub write does. Captured by value so a failed
/// action can be retried verbatim without the UI reconstructing it.
enum GHActionKind: Sendable, Equatable {
    case review(kind: ReviewActionKind, body: String, comments: [GHClient.InlineComment])
    case merge(method: MergeMethod)
    /// Queue a merge to run server-side once the PR becomes mergeable
    /// (`gh pr merge --auto`). The method picks the eventual strategy.
    case enableAutoMerge(method: MergeMethod)
    /// Cancel a pending auto-merge request (`gh pr merge --disable-auto`).
    case disableAutoMerge
    /// Close review threads PRBar opened, in one batch. Queued rather than
    /// fired inline so it is serialized against the other writes to this
    /// PR, retryable, and recorded in History like everything else.
    case resolveThreads(ids: [String])
    /// Put back the review request a share consumed. Its own action, not a
    /// tail on the review post: the post has already succeeded and must not
    /// be re-sent if only this half fails.
    case requestReviewer(login: String)
}

/// Where an action originated. Drives which `ActionLogKind` is recorded
/// and whether cost is logged (an automated post carries the AI cost).
enum ActionSource: Sendable, Equatable {
    case manual
    /// Posted by the auto-approve / auto-deny policy rather than a user click.
    case automated
    /// Posted by the share-findings policy — automated, but deliberately
    /// carrying no verdict. Separate from `.automated` only so the action
    /// log can tell it apart; it posts the same COMMENT event an auto-deny
    /// would.
    case sharedFindings

    /// True for every write PRBar made on its own initiative.
    var isAutomated: Bool { self != .manual }
}

/// One captured GitHub write, fully self-describing so the queue can run
/// or re-run it on its own. `attempts` increments on each retry.
struct GHAction: Sendable, Identifiable, Equatable {
    let id: UUID
    let pr: InboxPR
    let kind: GHActionKind
    let source: ActionSource
    /// AI cost to log for automated entries; nil for manual writes.
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

    /// Transient "this just succeeded" marker per PR, keyed by `nodeId`.
    /// Set on a successful write and auto-cleared after a few seconds so
    /// the UI can flash a confirmation (a merged PR drops out of the open
    /// inbox, so without this a successful merge looks like a no-op). The
    /// value is the kind that succeeded, for a kind-specific message.
    private(set) var recentSuccess: [String: GHActionKind] = [:]

    /// Per-PR token so a delayed clear only removes the success it scheduled
    /// (a newer success replaces the token and keeps its own window alive).
    @ObservationIgnored
    private var successTokens: [String: UUID] = [:]

    /// How long a success confirmation stays visible.
    @ObservationIgnored
    var successDisplayDuration: Duration = .seconds(5)

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

    /// Enables auto-merge on a PR (`gh pr merge --auto`). Injected so tests
    /// don't shell out.
    @ObservationIgnored
    var autoMergeExecutor: @Sendable (_ pr: InboxPR, _ method: MergeMethod) async throws -> Void = { _, _ in }

    /// Disables a pending auto-merge request. Injected so tests don't shell out.
    @ObservationIgnored
    var disableAutoMergeExecutor: @Sendable (_ pr: InboxPR) async throws -> Void = { _ in }

    /// Re-adds a login to a PR's requested reviewers. Injected so tests
    /// don't shell out. Only invoked on the `.sharedFindings` path.
    @ObservationIgnored
    var reRequestReviewerExecutor: @Sendable (_ pr: InboxPR, _ login: String) async throws -> Void = { _, _ in }

    /// Resolves one review thread by node id. Injected so tests don't
    /// shell out.
    @ObservationIgnored
    var resolveThreadExecutor: @Sendable (_ threadId: String) async throws -> Void = { _ in }

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
        q.autoMergeExecutor = { pr, method in
            let c = try client ?? GHClient()
            try await c.mergePR(
                owner: pr.owner, repo: pr.repo, number: pr.number,
                method: method, deleteBranch: false, auto: true
            )
        }
        q.disableAutoMergeExecutor = { pr in
            let c = try client ?? GHClient()
            try await c.disableAutoMerge(
                owner: pr.owner, repo: pr.repo, number: pr.number
            )
        }
        q.reRequestReviewerExecutor = { pr, login in
            let c = try client ?? GHClient()
            try await c.requestReviewer(
                owner: pr.owner, repo: pr.repo, number: pr.number, login: login
            )
        }
        q.resolveThreadExecutor = { threadId in
            let c = try client ?? GHClient()
            try await c.resolveReviewThread(threadId: threadId)
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
        let mergeMethod: MergeMethod?
        switch kind {
        case .merge(let m), .enableAutoMerge(let m): mergeMethod = m
        default: mergeMethod = nil
        }
        if let method = mergeMethod, !pr.allowedMergeMethods.contains(method) {
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
            case .resolveThreads(let ids):
                try await resolveThreads(ids)
                recordSuccess(action)
            case .requestReviewer(let login):
                try await reRequestReviewerExecutor(pr, login)
                recordSuccess(action)
            case .merge(let method):
                try await mergeExecutor(pr, method)
                recordSuccess(action)
            case .enableAutoMerge(let method):
                try await autoMergeExecutor(pr, method)
                recordSuccess(action)
            case .disableAutoMerge:
                try await disableAutoMergeExecutor(pr)
                recordSuccess(action)
            }
            // Terminal success: drop the slot, flash a confirmation, and
            // let the caller refresh.
            entries[nodeId] = nil
            noteSuccess(action)
            onActionCompleted?(pr)
            enqueueReRequestAfterShare(action)
        } catch {
            let msg = error.localizedDescription
            entries[nodeId]?.state = .failed(msg)
            recordFailure(action, message: msg)
            PRBarLog.actions.error("run failed pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public) error=\(msg, privacy: .public)")
        }
    }

    /// Queue the review request that the share post just consumed.
    ///
    /// Only for `.sharedFindings`: an auto-approve or auto-deny *is* the
    /// user's verdict, so GitHub clearing the request is correct there. A
    /// share deliberately casts no verdict, so leaving the request cleared
    /// would drop the PR out of the inbox and silently end retriage — the
    /// opposite of the feature's intent.
    ///
    /// A separate queued action rather than a tail on the review post,
    /// because the two fail differently. The comment has already landed on
    /// the PR; re-running the review action to fix a failed re-request
    /// would post it twice. As its own entry it retries on its own, shows
    /// up in the failed-action UI, and logs its own History row — which
    /// matters more here than anywhere else, since the whole reason this
    /// exists is that the failure is otherwise invisible.
    private func enqueueReRequestAfterShare(_ action: GHAction) {
        guard action.source == .sharedFindings else { return }
        guard case .review = action.kind else { return }
        let pr = action.pr
        guard !pr.viewerLogin.isEmpty else {
            PRBarLog.actions.error("re-request skipped pr=\(pr.nameWithOwner, privacy: .public)#\(pr.number, privacy: .public) reason=no-viewer-login")
            actionLog?.record(
                kind: .reviewReRequested, outcome: .failure, pr: pr,
                errorMessage: "No viewer login on the PR; PRBar can't name the reviewer to restore.",
                headSha: pr.headSha
            )
            return
        }
        enqueue(pr, kind: .requestReviewer(login: pr.viewerLogin), source: .sharedFindings)
    }

    /// Resolve a batch of threads, stopping at the first failure so the
    /// action's `.failed` entry means what it says and a retry re-runs the
    /// remainder. Resolving an already-resolved thread is a no-op on
    /// GitHub's side, so a retry re-running earlier ids is harmless.
    private func resolveThreads(_ ids: [String]) async throws {
        for id in ids {
            try await resolveThreadExecutor(id)
        }
    }

    /// Flash a success marker for this PR and schedule its removal. A newer
    /// success replaces the token so the older clear becomes a no-op.
    private func noteSuccess(_ action: GHAction) {
        let nodeId = action.pr.nodeId
        let token = UUID()
        recentSuccess[nodeId] = action.kind
        successTokens[nodeId] = token
        let duration = successDisplayDuration
        Task { @MainActor in
            try? await Task.sleep(for: duration)
            if successTokens[nodeId] == token {
                recentSuccess[nodeId] = nil
                successTokens[nodeId] = nil
            }
        }
    }

    // MARK: - logging

    private func recordSuccess(_ action: GHAction) {
        let (kind, detail) = Self.logKindAndDetail(action)
        actionLog?.record(
            kind: kind, outcome: .success, pr: action.pr,
            detail: detail,
            headSha: action.source.isAutomated ? action.pr.headSha : nil,
            costUsd: action.costUsd
        )
    }

    private func recordFailure(_ action: GHAction, message: String) {
        let (kind, detail) = Self.logKindAndDetail(action)
        actionLog?.record(
            kind: kind, outcome: .failure, pr: action.pr,
            errorMessage: message, detail: detail,
            headSha: action.source.isAutomated ? action.pr.headSha : nil,
            costUsd: action.costUsd
        )
    }

    private static func logKindAndDetail(_ action: GHAction) -> (ActionLogKind, String?) {
        switch action.kind {
        case .review(let kind, let body, _):
            let logKind: ActionLogKind
            switch action.source {
            case .manual:         logKind = kind.actionLogKind
            case .automated:      logKind = kind.autoActionLogKind
            case .sharedFindings: logKind = .autoShare
            }
            return (logKind, body.isEmpty ? nil : body)
        case .resolveThreads(let ids):
            return (.autoResolveThreads, "\(ids.count) thread\(ids.count == 1 ? "" : "s")")
        case .requestReviewer(let login):
            return (.reviewReRequested, login)
        case .merge(let method):
            return (.merge, method.rawValue)
        case .enableAutoMerge(let method):
            return (.autoMergeEnable, method.rawValue)
        case .disableAutoMerge:
            return (.autoMergeDisable, nil)
        }
    }

    private static func label(_ kind: GHActionKind) -> String {
        switch kind {
        case .review(let k, _, _): return "review(\(k.rawValue))"
        case .merge(let m): return "merge(\(m.rawValue))"
        case .enableAutoMerge(let m): return "enableAutoMerge(\(m.rawValue))"
        case .disableAutoMerge: return "disableAutoMerge"
        case .resolveThreads(let ids): return "resolveThreads(\(ids.count))"
        case .requestReviewer(let l): return "requestReviewer(\(l))"
        }
    }
}
