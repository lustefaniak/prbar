import Foundation
import Observation

/// A front end's view of the PRBar server: one API connection, the state
/// it renders kept up to date from the server's `state` updates, and the
/// commands it sends back. The app's views read the models here instead of
/// the runtime, so they work the same whether the server runs in the app's
/// own process or elsewhere.
@MainActor
@Observable
final class ServerSession {
    let inbox: InboxModel
    let reviews: ReviewQueueModel
    let actions: ActionQueueModel
    let diffs: DiffModel
    let ciLogs: CILogModel
    let config: ConfigModel
    let actionLog: ActionLogModel
    let reviewLog: ReviewLogModel

    enum Connection: Equatable {
        case connecting
        case connected(HelloResult)
        /// Lost, and trying again; the message says why.
        case disconnected(String)

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    /// Whether the views are showing live state. A banner reads this.
    private(set) var connection: Connection = .connecting

    @ObservationIgnored
    private var client: APIClient?
    @ObservationIgnored
    private var connect: (@MainActor () async throws -> ServerConnection.Connected)?
    @ObservationIgnored
    private var runTask: Task<Void, Never>?
    @ObservationIgnored
    private var listener: Task<Void, Never>?
    @ObservationIgnored
    private var notificationListener: Task<Void, Never>?
    /// What this front end told the server about itself, replayed on every
    /// reconnect: a restarted server knows none of it.
    @ObservationIgnored
    private var preferences = PreferencesParams()
    @ObservationIgnored
    private var popoverVisible: Bool?

    /// A session over one fixed connection (tests, and the in-process
    /// server, which can't go away).
    convenience init(client: APIClient) {
        self.init()
        self.client = client
    }

    /// A session that connects with `connect`, and again whenever the
    /// connection drops (`run`).
    convenience init(connect: @escaping @MainActor () async throws -> ServerConnection.Connected) {
        self.init()
        self.connect = connect
    }

    private init() {
        inbox = InboxModel()
        reviews = ReviewQueueModel()
        actions = ActionQueueModel()
        diffs = DiffModel()
        ciLogs = CILogModel()
        config = ConfigModel()
        actionLog = ActionLogModel()
        reviewLog = ReviewLogModel()
        inbox.session = self
        reviews.session = self
        actions.session = self
        diffs.session = self
        ciLogs.session = self
        config.session = self
        reviewLog.session = self
    }

    /// Subscribes over the current connection, applies the snapshot, then
    /// follows updates until the connection closes. With `deliverer`, this
    /// front end shows the server's notifications.
    func start(deliverer: (any NotificationDeliverer)? = nil) async throws {
        guard let client else { throw APIClientError.disconnected }
        let params = SubscribeParams(state: true, notifications: deliverer != nil)
        let result = try await client.call(.subscribe, params, as: SubscribeResult.self)
        if let snapshot = result.state { apply(snapshot) }
        let updates = client.stateUpdates
        listener = Task { [weak self] in
            for await update in updates {
                self?.apply(update)
            }
        }
        if let deliverer {
            let batches = client.notifications
            notificationListener = Task {
                for await batch in batches {
                    await deliverer.deliver(batch.events)
                }
            }
        }
    }

    /// Connects, subscribes and follows the server, reconnecting with a
    /// backoff whenever the connection drops, until `stop`.
    func run(deliverer: (any NotificationDeliverer)? = nil) {
        guard let connect, runTask == nil else { return }
        runTask = Task { [weak self] in
            var delay: Duration = .milliseconds(500)
            while !Task.isCancelled {
                do {
                    let connected = try await connect()
                    guard let self else { return }
                    self.client = connected.client
                    self.replayClientSettings()
                    try await self.start(deliverer: deliverer)
                    self.connection = .connected(connected.hello)
                    delay = .milliseconds(500)
                    // Until the server closes the connection.
                    await self.listener?.value
                    self.connection = .disconnected("the PRBar server closed the connection")
                } catch {
                    self?.connection = .disconnected(error.localizedDescription)
                }
                self?.client?.close()
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(5))
            }
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        listener?.cancel()
        listener = nil
        notificationListener?.cancel()
        notificationListener = nil
        client?.close()
    }

    private func replayClientSettings() {
        send(.setPreferences, preferences)
        if let popoverVisible { send(.setPopoverVisible, PopoverVisibility(visible: popoverVisible)) }
    }

    func apply(_ update: StateUpdate) {
        inbox.apply(update)
        reviews.apply(update)
        actions.apply(update)
        diffs.apply(update)
        ciLogs.apply(update)
        config.apply(update)
        actionLog.apply(update)
        reviewLog.apply(update)
    }

    /// `send` with the reply, delivered on the main actor in the order the
    /// replies arrive.
    func send<P: Codable & Sendable, R: Codable & Sendable>(
        _ method: APIMethod, _ params: P, as type: R.Type,
        completion: @escaping @MainActor (Result<R, Error>) -> Void
    ) {
        guard let client else {
            completion(.failure(APIClientError.disconnected))
            return
        }
        client.post(method, params, as: type) { result in
            Task { @MainActor in completion(result) }
        }
    }

    /// The one-time import of pre-file history runs in the app (it reads
    /// the old SwiftData store); the server shows its progress and reloads
    /// the logs when it's done.
    func reportHistoryImport(_ status: HistoryImportStatus?, finished: Bool) {
        send(.reportHistoryImport, HistoryImportState(actions: status, reviews: status))
        if finished { send(.reloadHistory, APIEmpty()) }
    }

    func setPreferences(_ preferences: PreferencesParams) {
        self.preferences.merge(preferences)
        send(.setPreferences, preferences)
    }

    /// While the user is looking at PRBar, the server holds notifications.
    func setPopoverVisible(_ visible: Bool) {
        popoverVisible = visible
        send(.setPopoverVisible, PopoverVisibility(visible: visible))
    }

    /// A request whose answer the caller needs.
    func call<P: Codable & Sendable, R: Codable & Sendable>(_ method: APIMethod, _ params: P, as type: R.Type) async throws -> R {
        guard let client else { throw APIClientError.disconnected }
        return try await client.call(method, params, as: type)
    }

    /// Fire-and-forget command, sent before this returns so commands reach
    /// the server in the order the UI issued them. A failure is logged: the
    /// state the UI shows comes back through `state` updates anyway.
    func send<P: Codable & Sendable>(_ method: APIMethod, _ params: P) {
        guard let client else {
            PRBarLog.lifecycle.notice("API \(method.rawValue, privacy: .public) dropped: not connected")
            return
        }
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
        didSet { session?.setPreferences(PreferencesParams(dailyCostCapEnabled: dailyCostCapEnabled)) }
    }
    @ObservationIgnored
    var dailyCostCap: Double = 0 {
        didSet { session?.setPreferences(PreferencesParams(dailyCostCapUsd: dailyCostCap)) }
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

/// `prbar.yaml` as the server has it, editable. Same names as the parts of
/// `RepoConfigStore` the views use.
///
/// Edits apply here at once (Settings binds text fields to these values and
/// can't wait a round trip per keystroke) and go to the server as the whole
/// config. While any of this model's writes are unanswered, config arriving
/// from the server is an echo of an older write and is ignored; the reply
/// to the last write is adopted, which also picks up a hand edit made in
/// the meantime.
@MainActor
@Observable
final class ConfigModel {
    private(set) var config = PRBarConfig()
    private(set) var path = ""
    private(set) var loadIssue: String?
    private(set) var warnings: [String] = []
    private(set) var migratedFromLegacy = false

    @ObservationIgnored
    weak var session: ServerSession?
    @ObservationIgnored
    private var unansweredWrites = 0

    var fileURL: URL { URL(fileURLWithPath: path) }
    var userConfigs: [RepoConfig] { config.repos }
    var providerOverrides: [ProviderID] { userConfigs.compactMap(\.providerOverride) }

    var defaults: ReviewDefaults {
        get { config.defaults }
        set { mutate { $0.defaults = newValue } }
    }

    var defaultProvider: ProviderChoice {
        get { config.defaultProvider }
        set { mutate { $0.defaultProvider = newValue } }
    }

    var defaultClaudeModel: String? {
        get { config.defaultClaudeModel }
        set { mutate { $0.defaultClaudeModel = newValue } }
    }

    var defaultClaudeEffort: String? {
        get { config.defaultClaudeEffort }
        set { mutate { $0.defaultClaudeEffort = newValue } }
    }

    var defaultCodexModel: String? {
        get { config.defaultCodexModel }
        set { mutate { $0.defaultCodexModel = newValue } }
    }

    var defaultCodexEffort: String? {
        get { config.defaultCodexEffort }
        set { mutate { $0.defaultCodexEffort = newValue } }
    }

    func resolve(owner: String, repo: String) -> ResolvedRepoConfig {
        config.resolve(owner: owner, repo: repo)
    }

    func rule(owner: String, repo: String) -> RepoConfig {
        config.rule(owner: owner, repo: repo)
    }

    func setAll(_ configs: [RepoConfig]) {
        mutate { $0.repos = configs }
    }

    func upsert(_ rule: RepoConfig) {
        mutate { config in
            if let idx = config.repos.firstIndex(where: { $0.id == rule.id }) {
                config.repos[idx] = rule
            } else {
                config.repos.append(rule)
            }
        }
    }

    func remove(id: UUID) {
        mutate { $0.repos.removeAll { $0.id == id } }
    }

    func apply(_ update: StateUpdate) {
        guard let state = update.config else { return }
        adopt(state, includingConfig: unansweredWrites == 0)
    }

    private func adopt(_ state: ConfigState, includingConfig: Bool) {
        if includingConfig { config = state.config }
        path = state.path
        loadIssue = state.loadIssue
        warnings = state.warnings
        migratedFromLegacy = state.migratedFromLegacy
    }

    private func mutate(_ body: (inout PRBarConfig) -> Void) {
        var next = config
        body(&next)
        // SwiftUI writes bindings back on every edit; an unchanged value
        // must not reach the file.
        guard next != config else { return }
        config = next
        guard let session else { return }
        unansweredWrites += 1
        session.send(.setConfig, SetConfigParams(config: next), as: ConfigState.self) { [weak self] result in
            guard let self else { return }
            self.unansweredWrites -= 1
            switch result {
            case .success(let state):
                self.adopt(state, includingConfig: self.unansweredWrites == 0)
            case .failure(let error):
                self.loadIssue = "Could not save: \(error.localizedDescription)"
            }
        }
    }
}

/// The action history as the server has it. Same names as `ActionLogStore`.
@MainActor
@Observable
final class ActionLogModel {
    private(set) var entries: [ActionRecord] = []
    private(set) var importStatus: HistoryImportStatus?

    func apply(_ update: StateUpdate) {
        if let log = update.actionLog { entries = log.applied(to: entries) }
        if let status = update.historyImport { importStatus = status.actions }
    }

    func fetchAll(limit: Int? = nil) -> [ActionRecord] {
        guard let limit else { return entries }
        return Array(entries.prefix(limit))
    }
}

/// The review history as the server has it. Same names as `ReviewLogStore`;
/// full reviews are fetched on first use and kept.
@MainActor
@Observable
final class ReviewLogModel {
    private(set) var entries: [ReviewRecord] = []
    private(set) var importStatus: HistoryImportStatus?
    private var fullReviews: [UUID: AggregatedReview] = [:]
    private var missing: Set<UUID> = []
    /// Requests in flight. Not observed: it changes from inside view
    /// bodies' `review(for:)` calls.
    @ObservationIgnored
    private var requested: Set<UUID> = []

    @ObservationIgnored
    weak var session: ServerSession?

    func apply(_ update: StateUpdate) {
        if let log = update.reviewLog {
            entries = log.applied(to: entries)
            if log.reset != nil {
                fullReviews = [:]
                missing = []
                requested = []
            }
        }
        if let status = update.historyImport { importStatus = status.reviews }
    }

    func fetchAll(limit: Int? = nil) -> [ReviewRecord] {
        guard let limit else { return entries }
        return Array(entries.prefix(limit))
    }

    /// The stored review, or nil while it loads (`isLoadingReview`) or when
    /// there is none. Called from view bodies, so it only schedules the
    /// request; the answer lands as an observed change.
    func review(for id: UUID) -> AggregatedReview? {
        if let review = fullReviews[id] { return review }
        guard !missing.contains(id), !requested.contains(id), let session else { return nil }
        requested.insert(id)
        session.send(.fullReview, FullReviewParams(id: id), as: FullReviewResult.self) { [weak self] result in
            guard let self else { return }
            self.requested.remove(id)
            if case .success(let full) = result, let review = full.review {
                self.fullReviews[id] = review
            } else {
                self.missing.insert(id)
            }
        }
        return nil
    }

    /// True until the review has arrived or turned out not to exist.
    func isLoadingReview(_ id: UUID) -> Bool {
        fullReviews[id] == nil && !missing.contains(id)
    }

    func clearAll() {
        session?.send(.clearReviewHistory, APIEmpty())
    }
}
