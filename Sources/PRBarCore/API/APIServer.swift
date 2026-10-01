import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Where the API socket lives: next to the runtime lock, because only the
/// lock holder binds it.
enum ServerLocation {
    static func socketURL(stateDirectory: URL = ConfigLocation.stateDirectory()) -> URL {
        stateDirectory.appendingPathComponent("server.sock")
    }
}

enum PRBarBuild {
    /// Stamped by the release workflow into Linux builds, which have no
    /// Info.plist to read. Leave it "dev" in the source.
    static let stamped = "dev"

    /// The app's marketing version and build number (the bundled CLI reads
    /// the app's Info.plist too), else the stamped version.
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let marketing = info["CFBundleShortVersionString"] as? String else { return stamped }
        if let build = info["CFBundleVersion"] as? String { return "\(marketing) (\(build))" }
        return marketing
    }
}

/// Serves one `PRBarRuntime` to API clients over the Unix socket. Runs in
/// whichever process holds the runtime lock: the app today, or
/// `prbar-review serve`.
///
/// Every request is answered on the main actor, where the runtime lives;
/// the socket I/O happens on threads of its own.
@MainActor
final class APIServer {
    let runtime: PRBarRuntime
    let holder: String
    let build: String
    let startedAt = Date()
    /// How a client's `shutdown` request is carried out. Nil refuses it:
    /// the app hosting the server is not something a CLI should quit.
    var onShutdown: (@MainActor () -> Void)?

    private var socketURL: URL?
    private let stopFlag = StopFlag()
    private var connections: [ObjectIdentifier: any APIConnection] = [:]
    /// Connections that asked for `event`s / `state` updates.
    private var subscribers: [ObjectIdentifier: any APIConnection] = [:]
    private var stateSubscribers: [ObjectIdentifier: any APIConnection] = [:]
    /// What each connection said about itself in `hello`.
    private var clients: [ObjectIdentifier: HelloParams] = [:]
    private var observer: UUID?
    private var trackers: [AnyObject] = []

    init(runtime: PRBarRuntime, holder: String, build: String = PRBarBuild.version) {
        self.runtime = runtime
        self.holder = holder
        self.build = build
        observer = runtime.observe { [weak self] event in self?.broadcast(event) }
        trackState()
    }

    /// Binds the socket and starts accepting. The caller must hold the
    /// runtime lock: binding removes whatever file is at the path.
    func start(socketURL: URL) throws {
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let listener = try UnixSocket.listen(path: socketURL.path)
        self.socketURL = socketURL

        // The accept thread never touches the server: it hands each
        // connection to the main actor through a stream.
        let (accepted, sink) = AsyncStream<LineConnection>.makeStream()
        let flag = stopFlag
        let thread = Thread {
            while !flag.isSet {
                guard let fd = UnixSocket.accept(listener, timeoutMs: 200) else { continue }
                sink.yield(LineConnection(fd: fd))
            }
            sink.finish()
            _ = close(listener)
        }
        thread.name = "prbar-api-accept"
        thread.start()
        Task { [weak self] in
            for await connection in accepted {
                guard let self, !self.stopFlag.isSet else {
                    connection.close()
                    continue
                }
                self.attach(connection)
            }
        }
    }

    func stop() {
        guard !stopFlag.isSet else { return }
        stopFlag.set()
        if let observer { runtime.removeObserver(observer) }
        observer = nil
        trackers.removeAll()
        for connection in connections.values { connection.close() }
        connections.removeAll()
        subscribers.removeAll()
        stateSubscribers.removeAll()
        if let socketURL { unlink(socketURL.path) }
    }

    // MARK: - Connections

    func register(_ connection: any APIConnection) {
        connections[ObjectIdentifier(connection)] = connection
    }

    private func attach(_ connection: LineConnection) {
        let key = ObjectIdentifier(connection)
        register(connection)
        connection.startReading(
            onLine: { line in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let reply = await self.handle(line, from: connection)
                    if let reply { connection.send(reply) }
                }
            },
            onClose: {
                Task { @MainActor [weak self] in
                    self?.connections[key] = nil
                    self?.subscribers[key] = nil
                    self?.stateSubscribers[key] = nil
                    self?.clients[key] = nil
                }
            }
        )
    }

    private func broadcast(_ event: PRBarRuntime.Event) {
        guard !subscribers.isEmpty else { return }
        let message = RPCRequest(id: nil, method: APIMethod.event.rawValue, params: Self.apiEvent(event))
        guard let line = try? RPCLine.encode(message) else { return }
        for (key, connection) in subscribers where !connection.send(line) {
            subscribers[key] = nil
        }
    }

    // MARK: - State

    private func trackState() {
        let poller = runtime.poller, queue = runtime.queue, actionQueue = runtime.actionQueue
        let diffs = runtime.diffStore, ciLogs = runtime.failureLogs
        trackers = [
            StateTracker(read: { poller.prs }) { [weak self] prs in
                self?.publish(StateUpdate(prs: prs))
            },
            StateTracker(read: { Self.polling(poller) }) { [weak self] polling in
                self?.publish(StateUpdate(polling: polling))
            },
            trackEntries(read: { queue.reviews }) { changed, removed in
                StateUpdate(reviews: changed, removedReviews: removed)
            },
            trackEntries(read: { diffs.statuses }) { changed, removed in
                StateUpdate(diffs: changed, removedDiffs: removed)
            },
            trackEntries(read: { ciLogs.statuses }) { changed, removed in
                StateUpdate(ciLogs: changed, removedCILogs: removed)
            },
            StateTracker(read: { queue.liveProgress }) { [weak self] progress in
                self?.publish(StateUpdate(progress: progress))
            },
            StateTracker(read: { Self.autoReview(queue) }) { [weak self] autoReview in
                self?.publish(StateUpdate(autoReview: autoReview))
            },
            StateTracker(read: { Self.actions(actionQueue) }) { [weak self] actions in
                self?.publish(StateUpdate(actions: actions))
            },
        ]
    }

    /// Follows a dictionary and publishes only the entries that changed or
    /// went away, for state where each entry can be large.
    private func trackEntries<Value: Equatable>(
        read: @escaping @MainActor () -> [String: Value],
        update: @escaping @MainActor (_ changed: [String: Value]?, _ removed: [String]?) -> StateUpdate
    ) -> StateTracker<[String: Value]> {
        var sent = read()
        return StateTracker(read: read) { [weak self] current in
            let changed = current.filter { sent[$0.key] != $0.value }
            let removed = sent.keys.filter { current[$0] == nil }.sorted()
            sent = current
            self?.publish(update(changed.isEmpty ? nil : changed, removed.isEmpty ? nil : removed))
        }
    }

    /// Everything a front end renders, for a new state subscriber.
    func snapshot() -> StateUpdate {
        let queue = runtime.queue
        return StateUpdate(
            prs: runtime.poller.prs,
            polling: Self.polling(runtime.poller),
            reviews: queue.reviews,
            progress: queue.liveProgress,
            autoReview: Self.autoReview(queue),
            actions: Self.actions(runtime.actionQueue),
            diffs: runtime.diffStore.statuses,
            ciLogs: runtime.failureLogs.statuses)
    }

    private static func actions(_ queue: ActionQueue) -> ActionQueueState {
        ActionQueueState(entries: queue.entries, recentSuccess: queue.recentSuccess)
    }

    private static func autoReview(_ queue: ReviewQueueWorker) -> AutoReviewState {
        AutoReviewState(
            pending: queue.pendingAutoActions,
            flagged: queue.flaggedDenials,
            batchUndoActive: queue.batchUndoActive,
            batchUndoDeadline: queue.batchUndoDeadline)
    }

    private static func polling(_ poller: PRPoller) -> PollingState {
        PollingState(
            lastFetchedAt: poller.lastFetchedAt,
            lastError: poller.lastError,
            isFetching: poller.isFetching,
            refreshingPRs: poller.refreshingPRs)
    }

    private func publish(_ update: StateUpdate) {
        guard !stateSubscribers.isEmpty, !update.isEmpty else { return }
        let message = RPCRequest(id: nil, method: APIMethod.state.rawValue, params: update)
        guard let line = try? RPCLine.encode(message) else { return }
        for (key, connection) in stateSubscribers where !connection.send(line) {
            stateSubscribers[key] = nil
        }
    }

    static func apiEvent(_ event: PRBarRuntime.Event) -> APIEvent {
        switch event {
        case .inboxChanged(let prs):
            return APIEvent(kind: .inboxChanged, count: prs.count)
        case .reviewSettled(let nodeId):
            return APIEvent(kind: .reviewSettled, prNodeId: nodeId)
        case .actionCompleted(let pr):
            return APIEvent(kind: .actionCompleted, prNodeId: pr.nodeId, pr: "\(pr.nameWithOwner)#\(pr.number)")
        case .configChanged:
            return APIEvent(kind: .configChanged)
        }
    }

    // MARK: - Requests

    /// The reply line for one request; nil for a notification, which gets
    /// none.
    func handle(_ line: Data, from connection: (any APIConnection)?) async -> Data? {
        guard let header = try? RPCLine.decode(RPCHeader.self, from: line) else {
            return Self.failure(id: nil, RPCError(code: RPCError.parseError, message: "not a JSON-RPC message"))
        }
        guard let name = header.method else {
            return Self.failure(id: header.id, RPCError(code: RPCError.invalidRequest, message: "missing method"))
        }
        guard let method = APIMethod(rawValue: name), !method.isNotification else {
            return Self.failure(id: header.id, RPCError(code: RPCError.methodNotFound, message: "unknown method \(name)"))
        }
        let id = header.id
        if method != .hello, let connection, let client = clients[ObjectIdentifier(connection)],
           client.agent == true, let denial = Self.denial(of: method, by: client, under: runtime.repoConfigs.config.agents) {
            PRBarLog.lifecycle.notice("API: refused \(method.rawValue, privacy: .public) from \(client.client, privacy: .public)")
            return Self.failure(id: id, denial)
        }

        switch method {
        case .hello:
            return await reply(line, id, HelloParams.self) { params in
                guard let params else { throw Self.missingParams }
                if let connection { self.clients[ObjectIdentifier(connection)] = params }
                guard APIVersion.supported.contains(params.protocolVersion) else {
                    throw RPCError(
                        code: RPCError.incompatibleVersion,
                        message: "client speaks protocol \(params.protocolVersion), this server \(Self.describe(APIVersion.supported))")
                }
                return HelloResult(
                    minProtocolVersion: APIVersion.supported.lowerBound,
                    maxProtocolVersion: APIVersion.supported.upperBound,
                    holder: self.holder, build: self.build, pid: getpid())
            }
        case .status:
            return await reply(line, id, APIEmpty.self) { _ in self.status() }
        case .inbox:
            return await reply(line, id, APIEmpty.self) { _ in self.runtime.poller.prs }
        case .refreshPR:
            return await reply(line, id, RefreshParams.self) { params in
                guard let params, let pr = self.findPR(params.pr) else {
                    throw RPCError(code: RPCError.notFound, message: "no such PR in the inbox")
                }
                self.runtime.poller.refreshPR(pr, force: params.force ?? false)
                return APIEmpty()
            }
        case .review:
            return await reply(line, id, PRReference.self) { ref in
                guard let ref, let pr = self.findPR(ref) else {
                    throw RPCError(code: RPCError.notFound, message: "no such PR in the inbox")
                }
                return ReviewResult(pr: pr, review: self.runtime.queue.reviews[pr.nodeId])
            }
        case .runReview:
            return await reply(line, id, RunReviewParams.self) { params in
                guard let params, let pr = self.findPR(params.pr) else {
                    throw RPCError(code: RPCError.notFound, message: "no such PR in the inbox")
                }
                self.runtime.queue.enqueue(pr, force: params.force ?? false, providerOverride: params.provider)
                return ReviewResult(pr: pr, review: self.runtime.queue.reviews[pr.nodeId])
            }
        case .enqueueAction:
            return await reply(line, id, EnqueueActionParams.self) { params in
                guard let params else { throw Self.missingParams }
                if let connection, let client = self.clients[ObjectIdentifier(connection)], client.agent == true,
                   let denial = Self.denial(of: params.kind, under: self.runtime.repoConfigs.config.agents) {
                    throw denial
                }
                self.runtime.actionQueue.enqueue(params.pr, kind: params.kind, source: .manual)
                return APIEmpty()
            }
        case .retryAction:
            return await reply(line, id, ActionTarget.self) { params in
                guard let params else { throw Self.missingParams }
                self.runtime.actionQueue.retry(params.prNodeId)
                return APIEmpty()
            }
        case .dismissAction:
            return await reply(line, id, ActionTarget.self) { params in
                guard let params else { throw Self.missingParams }
                self.runtime.actionQueue.dismissFailure(params.prNodeId)
                return APIEmpty()
            }
        case .loadDiff:
            return await reply(line, id, PRSnapshot.self) { params in
                guard let params else { throw Self.missingParams }
                self.runtime.diffStore.ensureLoaded(for: params.pr)
                return APIEmpty()
            }
        case .invalidateDiff:
            return await reply(line, id, PRSnapshot.self) { params in
                guard let params else { throw Self.missingParams }
                self.runtime.diffStore.invalidate(for: params.pr)
                return APIEmpty()
            }
        case .loadCILog:
            return await reply(line, id, CILogParams.self) { params in
                guard let params else { throw Self.missingParams }
                self.runtime.failureLogs.ensureLoaded(for: params.pr, check: params.check)
                return APIEmpty()
            }
        case .invalidateCILog:
            return await reply(line, id, CILogParams.self) { params in
                guard let params else { throw Self.missingParams }
                self.runtime.failureLogs.invalidate(for: params.pr, check: params.check)
                return APIEmpty()
            }
        case .autoReviewUndo:
            return await reply(line, id, APIEmpty.self) { _ in
                self.runtime.queue.cancelAutoReviewBatch()
                return APIEmpty()
            }
        case .autoReviewPostNow:
            return await reply(line, id, APIEmpty.self) { _ in
                self.runtime.queue.fireAutoReviewBatchNow()
                return APIEmpty()
            }
        case .autoReviewDismissFlagged:
            return await reply(line, id, APIEmpty.self) { _ in
                self.runtime.queue.dismissAllFlaggedDenials()
                return APIEmpty()
            }
        case .setCostCap:
            return await reply(line, id, CostCapParams.self) { params in
                if let enabled = params?.enabled { self.runtime.queue.dailyCostCapEnabled = enabled }
                if let usd = params?.usd { self.runtime.queue.dailyCostCap = max(0, usd) }
                return APIEmpty()
            }
        case .checkoutUsage:
            return await reply(line, id, APIEmpty.self) { _ in
                CheckoutUsage(bytes: await self.runtime.queue.checkoutManager?.totalCacheBytes() ?? 0)
            }
        case .checkoutPrune:
            return await reply(line, id, APIEmpty.self) { _ in
                await self.runtime.queue.checkoutManager?.pruneAllBareClones()
                return CheckoutUsage(bytes: await self.runtime.queue.checkoutManager?.totalCacheBytes() ?? 0)
            }
        case .historyActions:
            return await reply(line, id, HistoryParams.self) { params in
                Self.limited(self.runtime.actionLog.entries, params?.limit)
            }
        case .historyReviews:
            return await reply(line, id, HistoryParams.self) { params in
                Self.limited(self.runtime.reviewLog.entries, params?.limit)
            }
        case .poll:
            return await reply(line, id, APIEmpty.self) { _ in
                self.runtime.poller.pollNow()
                return APIEmpty()
            }
        case .subscribe:
            return await reply(line, id, SubscribeParams.self) { params in
                let wantsState = params?.state ?? false
                if let connection {
                    self.subscribers[ObjectIdentifier(connection)] = connection
                    if wantsState { self.stateSubscribers[ObjectIdentifier(connection)] = connection }
                }
                return SubscribeResult(status: self.status(), state: wantsState ? self.snapshot() : nil)
            }
        case .shutdown:
            guard let onShutdown else {
                return Self.failure(id: id, RPCError(code: RPCError.refused, message: "\(holder) does not shut down on request"))
            }
            // After the reply is on its way, so the client hears back.
            Task { @MainActor in onShutdown() }
            return await reply(line, id, APIEmpty.self) { _ in APIEmpty() }
        case .event, .state:
            return nil
        }
    }

    /// Why an agent may not call `method`, or nil when it may.
    nonisolated static func denial(of method: APIMethod, by client: HelloParams, under policy: AgentPolicy) -> RPCError? {
        let capability: AgentPolicy.Capability
        switch method {
        case .hello, .event, .state:
            return nil
        case .status, .inbox, .refreshPR, .review, .historyActions, .historyReviews, .poll, .subscribe,
             .loadDiff, .invalidateDiff, .loadCILog, .invalidateCILog:
            capability = .read
        case .runReview:
            capability = .review
        case .enqueueAction:
            // Post or merge depends on the action, so the handler decides
            // with `denial(of:under:)` once it has read the params.
            return nil
        case .retryAction, .dismissAction:
            capability = .post
        case .shutdown:
            return RPCError(code: RPCError.notPermitted, message: "coding agents can't stop the PRBar server")
        case .autoReviewUndo, .autoReviewPostNow, .autoReviewDismissFlagged, .setCostCap, .checkoutUsage, .checkoutPrune:
            return RPCError(code: RPCError.notPermitted, message: "\(method.rawValue) is for the user's own PRBar, not for coding agents")
        }
        switch policy[capability] {
        case .allow:
            return nil
        case .off:
            return RPCError(
                code: RPCError.notPermitted,
                message: "PRBar's agents.\(capability.rawValue) is off in prbar.yaml, so coding agents can't do this")
        case .ask:
            return RPCError(
                code: RPCError.notPermitted,
                message: "PRBar's agents.\(capability.rawValue) is `ask`, and approving agent requests in PRBar isn't available yet; set it to `allow` to let agents do this")
        }
    }

    /// Merges need `agents.merge`; every other write `agents.post`.
    nonisolated static func denial(of kind: GHActionKind, under policy: AgentPolicy) -> RPCError? {
        let capability: AgentPolicy.Capability
        switch kind {
        case .merge, .enableAutoMerge, .disableAutoMerge: capability = .merge
        case .review, .resolveThreads, .requestReviewer: capability = .post
        }
        guard policy[capability] != .allow else { return nil }
        return RPCError(
            code: RPCError.notPermitted,
            message: "PRBar's agents.\(capability.rawValue) is \(policy[capability].rawValue) in prbar.yaml, so coding agents can't do this")
    }

    func status() -> ServerStatus {
        let prs = runtime.poller.prs
        let states = runtime.queue.reviews.values
        return ServerStatus(
            holder: holder,
            build: build,
            pid: getpid(),
            startedAt: startedAt,
            ownsAutomation: runtime.ownsAutomation,
            lastPollAt: runtime.poller.lastFetchedAt,
            lastPollError: runtime.poller.lastError,
            prCount: prs.count,
            awaitingReview: prs.filter { $0.role == .reviewRequested || $0.role == .both }.count,
            reviewsQueued: states.filter { if case .queued = $0.status { return true }; return false }.count,
            reviewsRunning: states.filter { if case .running = $0.status { return true }; return false }.count,
            configPath: runtime.repoConfigs.fileURL.path,
            configIssue: runtime.repoConfigs.loadIssue,
            configWarnings: runtime.repoConfigs.warnings
        )
    }

    private func findPR(_ ref: PRReference) -> InboxPR? {
        let prs = runtime.poller.prs
        if let nodeId = ref.nodeId { return prs.first { $0.nodeId == nodeId } }
        guard let owner = ref.owner, let repo = ref.repo, let number = ref.number else { return nil }
        return prs.first {
            $0.owner.caseInsensitiveCompare(owner) == .orderedSame
                && $0.repo.caseInsensitiveCompare(repo) == .orderedSame
                && $0.number == number
        }
    }

    // MARK: - Encoding

    private func reply<P: Codable & Sendable, R: Codable & Sendable>(
        _ line: Data, _ id: Int?, _: P.Type, _ body: (P?) async throws -> R
    ) async -> Data? {
        let params: P?
        do {
            params = try RPCLine.decode(RPCRequest<P>.self, from: line).params
        } catch {
            return Self.failure(id: id, RPCError(code: RPCError.invalidParams, message: "invalid params: \(error)"))
        }
        do {
            let result = try await body(params)
            return try? RPCLine.encode(RPCResponse(id: id, result: result))
        } catch let error as RPCError {
            return Self.failure(id: id, error)
        } catch {
            return Self.failure(id: id, RPCError(code: RPCError.internalError, message: error.localizedDescription))
        }
    }

    private static func failure(id: Int?, _ error: RPCError) -> Data? {
        try? RPCLine.encode(RPCResponse<APIEmpty>(id: id, error: error))
    }

    private static let missingParams = RPCError(code: RPCError.invalidParams, message: "missing params")

    private static func limited<T>(_ entries: [T], _ limit: Int?) -> [T] {
        guard let limit, limit >= 0 else { return entries }
        return Array(entries.prefix(limit))
    }

    nonisolated static func describe(_ range: ClosedRange<Int>) -> String {
        range.lowerBound == range.upperBound ? "\(range.lowerBound)" : "\(range.lowerBound)-\(range.upperBound)"
    }
}

final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
