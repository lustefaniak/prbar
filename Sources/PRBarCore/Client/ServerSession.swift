import Foundation
import Observation

/// A front end's view of the PRBar server: one API connection, the state
/// it renders kept up to date from the server's `state` updates, and the
/// commands it sends back. The app's views read the models here instead of
/// the runtime, so they work the same whether the server runs in the app's
/// own process or elsewhere.
@MainActor
final class ServerSession {
    let inbox: InboxModel
    let reviews: ReviewQueueModel
    let actions: ActionQueueModel
    let diffs: DiffModel
    let ciLogs: CILogModel

    private let client: APIClient
    private var listener: Task<Void, Never>?

    init(client: APIClient) {
        self.client = client
        inbox = InboxModel()
        reviews = ReviewQueueModel()
        actions = ActionQueueModel()
        diffs = DiffModel()
        ciLogs = CILogModel()
        inbox.session = self
        reviews.session = self
        actions.session = self
        diffs.session = self
        ciLogs.session = self
    }

    /// Subscribes, applies the snapshot, then follows updates until the
    /// connection closes.
    func start() async throws {
        let result = try await client.call(.subscribe, SubscribeParams(state: true), as: SubscribeResult.self)
        if let snapshot = result.state { apply(snapshot) }
        let updates = client.stateUpdates
        listener = Task { [weak self] in
            for await update in updates {
                self?.apply(update)
            }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        client.close()
    }

    func apply(_ update: StateUpdate) {
        inbox.apply(update)
        reviews.apply(update)
        actions.apply(update)
        diffs.apply(update)
        ciLogs.apply(update)
    }

    /// A request whose answer the caller needs.
    func call<P: Codable & Sendable, R: Codable & Sendable>(_ method: APIMethod, _ params: P, as type: R.Type) async throws -> R {
        try await client.call(method, params, as: type)
    }

    /// Fire-and-forget command, sent before this returns so commands reach
    /// the server in the order the UI issued them. A failure is logged: the
    /// state the UI shows comes back through `state` updates anyway.
    func send<P: Codable & Sendable>(_ method: APIMethod, _ params: P) {
        client.post(method, params) { error in
            PRBarLog.lifecycle.error("API \(method.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// The inbox as the server reports it: the PR list and the polling state.
/// Same names as `PRPoller`, which it mirrors.
@MainActor
@Observable
final class InboxModel {
    private(set) var prs: [InboxPR] = []
    private(set) var lastFetchedAt: Date?
    private(set) var lastError: String?
    private(set) var isFetching = false
    private(set) var refreshingPRs: Set<String> = []

    @ObservationIgnored
    weak var session: ServerSession?

    func apply(_ update: StateUpdate) {
        if let prs = update.prs { self.prs = prs }
        if let polling = update.polling {
            lastFetchedAt = polling.lastFetchedAt
            lastError = polling.lastError
            isFetching = polling.isFetching
            refreshingPRs = polling.refreshingPRs
        }
    }

    func pollNow() {
        session?.send(.poll, APIEmpty())
    }

    func refreshPR(_ pr: InboxPR, force: Bool = false) {
        session?.send(.refreshPR, RefreshParams(pr: PRReference(nodeId: pr.nodeId), force: force))
    }
}

/// AI reviews as the server reports them. Same names as the parts of
/// `ReviewQueueWorker` the views use.
@MainActor
@Observable
final class ReviewQueueModel {
    private(set) var reviews: [String: ReviewState] = [:]
    private(set) var liveProgress: [String: ReviewProgress] = [:]
    private(set) var pendingAutoActions: [String: ReviewQueueWorker.StagedAutoReview] = [:]
    private(set) var flaggedDenials: [String: ReviewQueueWorker.StagedAutoReview] = [:]
    private(set) var batchUndoActive = false
    private(set) var batchUndoDeadline: Date?

    /// Written by Settings, which keeps the values in its own preferences;
    /// setting one hands it to the server.
    @ObservationIgnored
    var dailyCostCapEnabled = true {
        didSet { session?.send(.setCostCap, CostCapParams(enabled: dailyCostCapEnabled)) }
    }
    @ObservationIgnored
    var dailyCostCap: Double = 0 {
        didSet { session?.send(.setCostCap, CostCapParams(usd: dailyCostCap)) }
    }

    @ObservationIgnored
    weak var session: ServerSession?

    func apply(_ update: StateUpdate) {
        if let changed = update.reviews {
            reviews.merge(changed) { _, new in new }
        }
        for nodeId in update.removedReviews ?? [] { reviews[nodeId] = nil }
        if let progress = update.progress { liveProgress = progress }
        if let auto = update.autoReview {
            pendingAutoActions = auto.pending
            flaggedDenials = auto.flagged
            batchUndoActive = auto.batchUndoActive
            batchUndoDeadline = auto.batchUndoDeadline
        }
    }

    func enqueue(_ pr: InboxPR, force: Bool = false, providerOverride: ProviderID? = nil) {
        session?.send(.runReview, RunReviewParams(pr: PRReference(nodeId: pr.nodeId), provider: providerOverride, force: force))
    }

    func cancelAutoReviewBatch() {
        session?.send(.autoReviewUndo, APIEmpty())
    }

    func fireAutoReviewBatchNow() {
        session?.send(.autoReviewPostNow, APIEmpty())
    }

    func dismissAllFlaggedDenials() {
        session?.send(.autoReviewDismissFlagged, APIEmpty())
    }

    /// Bytes used by the clones and worktrees reviews run in.
    func checkoutCacheBytes() async -> Int64 {
        (try? await session?.call(.checkoutUsage, APIEmpty(), as: CheckoutUsage.self).bytes) ?? 0
    }

    /// Deletes the bare clones; returns what is left.
    func pruneCheckouts() async -> Int64 {
        (try? await session?.call(.checkoutPrune, APIEmpty(), as: CheckoutUsage.self).bytes) ?? 0
    }
}

/// GitHub writes as the server's action queue reports them. Same names as
/// the parts of `ActionQueue` the views use.
@MainActor
@Observable
final class ActionQueueModel {
    private(set) var entries: [String: ActionEntry] = [:]
    private(set) var recentSuccess: [String: GHActionKind] = [:]

    @ObservationIgnored
    weak var session: ServerSession?

    func apply(_ update: StateUpdate) {
        guard let actions = update.actions else { return }
        entries = actions.entries
        recentSuccess = actions.recentSuccess
    }

    func state(for nodeId: String) -> ActionRunState? {
        entries[nodeId]?.state
    }

    func isBusy(_ nodeId: String) -> Bool {
        entries[nodeId]?.state.isBusy ?? false
    }

    /// The server applies the double-submit guard; `pr` is sent as the user
    /// saw it, so a review lands on the commit they reviewed.
    func enqueue(_ pr: InboxPR, kind: GHActionKind) {
        session?.send(.enqueueAction, EnqueueActionParams(pr: pr, kind: kind))
    }

    func retry(_ nodeId: String) {
        session?.send(.retryAction, ActionTarget(prNodeId: nodeId))
    }

    func dismissFailure(_ nodeId: String) {
        session?.send(.dismissAction, ActionTarget(prNodeId: nodeId))
    }
}

/// Parsed diffs, loaded on request. Same names as `DiffStore`. A diff is
/// `.idle` until the server's answer arrives, which is the window
/// `InlineCommentReadiness` already waits out before posting.
@MainActor
@Observable
final class DiffModel {
    private(set) var statuses: [String: DiffStore.LoadStatus] = [:]

    @ObservationIgnored
    weak var session: ServerSession?

    func apply(_ update: StateUpdate) {
        if let changed = update.diffs { statuses.merge(changed) { _, new in new } }
        for key in update.removedDiffs ?? [] { statuses[key] = nil }
    }

    func status(for pr: InboxPR) -> DiffStore.LoadStatus {
        statuses[DiffStore.key(for: pr)] ?? .idle
    }

    func ensureLoaded(for pr: InboxPR) {
        switch status(for: pr) {
        case .loading, .loaded: return
        case .idle, .failed: session?.send(.loadDiff, PRSnapshot(pr: pr))
        }
    }

    /// Marks the diff idle at once, so a reload that follows straight away
    /// asks the server again instead of seeing the old hunks.
    func invalidate(for pr: InboxPR) {
        statuses[DiffStore.key(for: pr)] = .idle
        session?.send(.invalidateDiff, PRSnapshot(pr: pr))
    }
}

/// CI failure log tails, loaded on request. Same names as
/// `FailureLogStore`.
@MainActor
@Observable
final class CILogModel {
    private(set) var statuses: [String: FailureLogStore.LoadStatus] = [:]

    @ObservationIgnored
    weak var session: ServerSession?

    func apply(_ update: StateUpdate) {
        if let changed = update.ciLogs { statuses.merge(changed) { _, new in new } }
        for key in update.removedCILogs ?? [] { statuses[key] = nil }
    }

    func status(for pr: InboxPR, check: CheckSummary) -> FailureLogStore.LoadStatus {
        guard let jobId = CIFailureLogTail.parseJobId(from: check.url) else {
            return .failed("No job log available for this check.")
        }
        return statuses[FailureLogStore.key(prNodeId: pr.nodeId, headSha: pr.headSha, jobId: jobId)] ?? .idle
    }

    func ensureLoaded(for pr: InboxPR, check: CheckSummary) {
        switch status(for: pr, check: check) {
        case .loading, .loaded: return
        case .idle, .failed: session?.send(.loadCILog, CILogParams(pr: pr, check: check))
        }
    }

    func invalidate(for pr: InboxPR, check: CheckSummary) {
        if let jobId = CIFailureLogTail.parseJobId(from: check.url) {
            statuses[FailureLogStore.key(prNodeId: pr.nodeId, headSha: pr.headSha, jobId: jobId)] = .idle
        }
        session?.send(.invalidateCILog, CILogParams(pr: pr, check: check))
    }
}
