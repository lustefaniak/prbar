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
    /// The process this server exits with, reported in `hello`.
    var exitsWith: Int32?
    /// For a server started on demand: how long it waits without clients
    /// before exiting, reported in `hello`.
    var idleExitSeconds: Int?
    /// How `server.adopt` is carried out: the server stops being on-demand
    /// and exits with the adopting app instead. Nil refuses it.
    var onAdopt: (@MainActor (Int32) -> Void)?
    /// Whether any client is connected, in process included.
    var hasClients: Bool { !connections.isEmpty }
    /// PRs fetched for `review.run` that aren't in the inbox, so later
    /// requests about them still resolve.
    private var fetched: [String: InboxPR] = [:]
    /// Tests only: runs at the start of every request, so a test can make
    /// one request slower than the next.
    var _beforeHandling: (@MainActor (APIMethod) async -> Void)?

    private var socketURL: URL?
    private let stopFlag = StopFlag()
    private var connections: [ObjectIdentifier: any APIConnection] = [:]
    /// Connections that asked for `event`s / `state` updates.
    private var subscribers: [ObjectIdentifier: any APIConnection] = [:]
    private var stateSubscribers: [ObjectIdentifier: any APIConnection] = [:]
    private var notificationSubscribers: [ObjectIdentifier: any APIConnection] = [:]
    /// What each connection said about itself in `hello`.
    private var clients: [ObjectIdentifier: HelloParams] = [:]
    /// The config revision each connection's last accepted write produced.
    private var lastConfigWrite: [ObjectIdentifier: Int] = [:]
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
        notificationSubscribers.removeAll()
        if let socketURL { unlink(socketURL.path) }
    }

    // MARK: - Connections

    func register(_ connection: any APIConnection) {
        connections[ObjectIdentifier(connection)] = connection
    }

    func registerClient(_ connection: any APIConnection, _ hello: HelloParams) {
        clients[ObjectIdentifier(connection)] = hello
    }

    /// Handles one connection's requests one at a time, in arrival order.
    /// A task per line would let a slow request be overtaken by the next
    /// one, and clients depend on order ("Reload diff" is invalidate then
    /// load). The cost: a slow request delays that client's later ones.
    func serve(_ connection: any APIConnection) -> AsyncStream<Data>.Continuation {
        let (lines, sink) = AsyncStream<Data>.makeStream()
        Task { [weak self] in
            for await line in lines {
                guard let self else { return }
                if let reply = await self.handle(line, from: connection) { connection.send(reply) }
            }
        }
        return sink
    }

    private func attach(_ connection: LineConnection) {
        let key = ObjectIdentifier(connection)
        register(connection)
        let requests = serve(connection)
        connection.startReading(
            onLine: { line in requests.yield(line) },
            onClose: {
                requests.finish()
                Task { @MainActor [weak self] in
                    self?.connections[key] = nil
                    self?.subscribers[key] = nil
                    self?.stateSubscribers[key] = nil
                    self?.notificationSubscribers[key] = nil
                    self?.clients[key] = nil
                    self?.lastConfigWrite[key] = nil
                }
            }
        )
    }

    private func broadcast(_ event: PRBarRuntime.Event) {
        guard !subscribers.isEmpty else { return }
        let message = RPCRequest(id: nil, method: APIMethod.event.rawValue, params: apiEvent(event))
        guard let line = try? RPCLine.encode(message) else { return }
        for (key, connection) in subscribers where !connection.send(line) {
            subscribers[key] = nil
        }
    }

    // MARK: - Notifications

    /// Routes the runtime's notifications to clients that show them.
    func relayNotifications(from relay: RelayDeliverer) {
        relay.attach { [weak self] events in
            await self?.forward(events) ?? false
        }
    }

    /// True when at least one client took the batch.
    func forward(_ events: [NotificationEvent]) -> Bool {
        guard !notificationSubscribers.isEmpty,
              let line = try? RPCLine.encode(RPCRequest(id: nil, method: APIMethod.notify.rawValue, params: NotificationBatch(events: events)))
        else { return false }
        var delivered = false
        for (key, connection) in notificationSubscribers {
            if connection.send(line) {
                delivered = true
            } else {
                notificationSubscribers[key] = nil
            }
        }
        return delivered
    }

    // MARK: - State

    private func trackState() {
        let poller = runtime.poller, queue = runtime.queue, actionQueue = runtime.actionQueue
        let diffs = runtime.diffStore, ciLogs = runtime.failureLogs, configs = runtime.repoConfigs
        let actionLog = runtime.actionLog, reviewLog = runtime.reviewLog
        var sentActions = actionLog.entries, sentReviewLog = reviewLog.entries
        trackers = [
            StateTracker(read: { actionLog.entries }) { [weak self] entries in
                defer { sentActions = entries }
                self?.publish(StateUpdate(actionLog: .between(sentActions, entries)))
            },
            StateTracker(read: { reviewLog.entries }) { [weak self] entries in
                defer { sentReviewLog = entries }
                self?.publish(StateUpdate(reviewLog: .between(sentReviewLog, entries)))
            },
            StateTracker(read: { HistoryImportState(actions: actionLog.importStatus, reviews: reviewLog.importStatus) }) { [weak self] state in
                self?.publish(StateUpdate(historyImport: state))
            },
            StateTracker(read: { Self.configState(configs) }) { [weak self] state in
                self?.publish(StateUpdate(config: state))
            },
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
            ciLogs: runtime.failureLogs.statuses,
            config: Self.configState(runtime.repoConfigs),
            actionLog: LogUpdate(reset: runtime.actionLog.entries),
            reviewLog: LogUpdate(reset: runtime.reviewLog.entries),
            historyImport: HistoryImportState(actions: runtime.actionLog.importStatus, reviews: runtime.reviewLog.importStatus))
    }

    static func configState(_ store: RepoConfigStore) -> ConfigState {
        ConfigState(
            config: store.config,
            revision: store.revision,
            path: store.fileURL.path,
            loadIssue: store.loadIssue,
            warnings: store.warnings,
            migratedFromLegacy: store.migratedFromLegacy,
            rulesIssue: store.rulesIssue)
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

    func apiEvent(_ event: PRBarRuntime.Event) -> APIEvent {
        switch event {
        case .inboxChanged(let prs):
            return APIEvent(kind: .inboxChanged, count: prs.count)
        case .reviewSettled(let nodeId):
            let pr = runtime.poller.prs.first { $0.nodeId == nodeId } ?? fetched[nodeId]
            return APIEvent(
                kind: .reviewSettled, prNodeId: nodeId,
                pr: pr.map(Self.displayName),
                detail: runtime.queue.reviews[nodeId].map { Self.outcome($0.status) })
        case .actionCompleted(let pr):
            return APIEvent(kind: .actionCompleted, prNodeId: pr.nodeId, pr: "\(pr.nameWithOwner)#\(pr.number)")
        case .configChanged:
            return APIEvent(kind: .configChanged)
        }
    }

    nonisolated static func outcome(_ status: ReviewState.Status) -> String {
        switch status {
        case .queued: return "queued"
        case .running: return "running"
        case .completed(let review): return "\(review.verdict.displayName), \(review.annotations.count) findings"
        case .failed(let message): return "failed: \(message)"
        case .skipped(let reason): return "skipped: \(reason.short)"
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
        await _beforeHandling?(method)
        // `hello` first: it agrees the protocol version and says whether the
        // client is an agent, which every later check depends on.
        if method != .hello, let connection, clients[ObjectIdentifier(connection)] == nil {
            return Self.failure(id: id, RPCError(code: RPCError.invalidRequest, message: "send hello first"))
        }
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
                    holder: self.holder, build: self.build, pid: getpid(), exitsWith: self.exitsWith,
                    idleExitSeconds: self.idleExitSeconds)
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
                guard let ref, let pr = self.findPR(try await Self.resolvingPath(ref)) else {
                    throw RPCError(code: RPCError.notFound, message: "no such PR in the inbox")
                }
                return ReviewResult(pr: pr, review: self.runtime.queue.reviews[pr.nodeId])
            }
        case .runReview:
            return await reply(line, id, RunReviewParams.self) { params in
                guard let params else { throw Self.missingParams }
                let pr = try await self.resolvePR(params.pr, fetch: params.fetch ?? false)
                let force = params.force ?? false
                let config = self.runtime.repoConfigs.resolve(owner: pr.owner, repo: pr.repo)
                if self.isAgent(connection) {
                    if let refusal = Self.agentReviewRefusal(
                        pr: pr, config: config, existing: self.runtime.queue.reviews[pr.nodeId], force: force) {
                        throw refusal
                    }
                }
                let ignored = self.queueReview(pr, config: config, params: params)
                let all = self.runtime.repoConfigs.config
                let provider = params.provider
                    ?? all.resolver()(pr.owner, pr.repo).providerOverride
                    ?? all.defaultProvider.resolve()
                return ReviewResult(pr: pr, review: self.runtime.queue.reviews[pr.nodeId], ignored: ignored, provider: provider)
            }
        case .reviewOutcome:
            return await reply(line, id, ReviewOutcomeParams.self) { params in
                guard let params else { throw Self.missingParams }
                guard let pr = self.findPR(try await Self.resolvingPath(params.pr)) else {
                    throw RPCError(code: RPCError.notFound, message: "no such PR in the inbox")
                }
                return self.outcome(of: pr, since: params.since)
            }
        case .explainRules:
            return await reply(line, id, ExplainRulesParams.self) { params in
                guard let params else { throw Self.missingParams }
                let ref = try await Self.resolvingPath(params.pr)
                let pr: InboxPR
                if let known = self.findPR(ref) {
                    pr = known
                } else {
                    pr = try await self.resolvePR(ref, fetch: true)
                }
                return self.explanation(of: pr)
            }
        case .reviewLocal:
            return await reply(line, id, LocalReviewParams.self) { params in
                guard let params else { throw Self.missingParams }
                let snapshot: LocalChanges.Snapshot
                do {
                    snapshot = try await LocalChanges.snapshot(at: params.path, base: params.base)
                } catch {
                    throw RPCError(code: RPCError.invalidParams, message: error.localizedDescription)
                }
                let pr = LocalChanges.pr(for: snapshot)
                let config = self.runtime.repoConfigs.resolve(owner: pr.owner, repo: pr.repo)
                if self.isAgent(connection), !config.aiReviewEnabled {
                    throw RPCError(code: RPCError.refused, message: "AI review is turned off for \(pr.nameWithOwner) in prbar.yaml. Coding agents can't override that; the user can in prbar.yaml.")
                }
                guard snapshot.changedFiles > 0 else {
                    return ReviewResult(pr: pr, review: nil, ignored: "no changes against \(snapshot.baseRef)")
                }
                self.fetched[pr.nodeId] = pr
                var ignored: String?
                if config.excluded {
                    ignored = "\(pr.nameWithOwner) is excluded by config"
                } else {
                    self.runtime.queue.enqueue(pr, force: params.force ?? false, providerOverride: params.provider)
                }
                let all = self.runtime.repoConfigs.config
                let provider = params.provider
                    ?? all.resolver()(pr.owner, pr.repo).providerOverride
                    ?? all.defaultProvider.resolve()
                return ReviewResult(pr: pr, review: self.runtime.queue.reviews[pr.nodeId], ignored: ignored, provider: provider)
            }
        case .enqueueAction:
            return await reply(line, id, EnqueueActionParams.self) { params in
                guard let params else { throw Self.missingParams }
                if self.isAgent(connection), let denial = Self.denial(of: params.kind, under: self.runtime.repoConfigs.config.agents) {
                    throw denial
                }
                self.runtime.actionQueue.enqueue(params.pr, kind: params.kind, source: .manual)
                return APIEmpty()
            }
        case .retryAction:
            return await reply(line, id, ActionTarget.self) { params in
                guard let params else { throw Self.missingParams }
                try self.authorizeAgent(connection, onActionFor: params.prNodeId)
                self.runtime.actionQueue.retry(params.prNodeId)
                return APIEmpty()
            }
        case .dismissAction:
            return await reply(line, id, ActionTarget.self) { params in
                guard let params else { throw Self.missingParams }
                try self.authorizeAgent(connection, onActionFor: params.prNodeId)
                self.runtime.actionQueue.dismissFailure(params.prNodeId)
                return APIEmpty()
            }
        case .fullReview:
            return await reply(line, id, FullReviewParams.self) { params in
                guard let params else { throw Self.missingParams }
                return FullReviewResult(review: self.runtime.reviewLog.review(for: params.id))
            }
        case .clearReviewHistory:
            return await reply(line, id, APIEmpty.self) { _ in
                self.runtime.reviewLog.clearAll()
                return APIEmpty()
            }
        case .reportHistoryImport:
            return await reply(line, id, HistoryImportState.self) { params in
                self.runtime.actionLog.importStatus = params?.actions
                self.runtime.reviewLog.importStatus = params?.reviews
                return APIEmpty()
            }
        case .reloadHistory:
            return await reply(line, id, APIEmpty.self) { _ in
                self.runtime.actionLog.reload()
                self.runtime.reviewLog.reload()
                return APIEmpty()
            }
        case .setPopoverVisible:
            return await reply(line, id, PopoverVisibility.self) { params in
                guard let params else { throw Self.missingParams }
                self.runtime.notifier.setPopoverVisible(params.visible)
                return APIEmpty()
            }
        case .setConfig:
            return await reply(line, id, SetConfigParams.self) { params in
                guard let params else { throw Self.missingParams }
                let store = self.runtime.repoConfigs
                let key = connection.map(ObjectIdentifier.init)
                // A burst of edits all name the revision they started from;
                // what moved since then must have been this client's own
                // previous write, or the edit is based on a stale copy.
                if let base = params.baseRevision, base != store.revision,
                   key.flatMap({ self.lastConfigWrite[$0] }) != store.revision {
                    throw RPCError(
                        code: RPCError.conflict,
                        message: "prbar.yaml changed while you were editing; your last change wasn't saved")
                }
                store.replace(with: params.config)
                if let key { self.lastConfigWrite[key] = store.revision }
                // The state the write produced, so the writer can adopt it
                // without waiting for (or racing) the state update.
                return Self.configState(self.runtime.repoConfigs)
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
        case .setPreferences:
            return await reply(line, id, PreferencesParams.self) { params in
                if let enabled = params?.dailyCostCapEnabled { self.runtime.queue.dailyCostCapEnabled = enabled }
                if let usd = params?.dailyCostCapUsd { self.runtime.queue.dailyCostCap = max(0, usd) }
                if let drafts = params?.notifyAuthoredDrafts { self.runtime.poller.includeAuthoredDrafts = drafts }
                if let seconds = params?.undoWindowSeconds { self.runtime.queue.undoWindow = max(0, seconds) }
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
                var entries = self.runtime.reviewLog.entries
                if let pr = params?.pr {
                    entries = entries.filter { Self.matches($0.owner, $0.repo, $0.prNumber, pr) }
                }
                return Self.limited(entries, params?.limit)
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
                    let key = ObjectIdentifier(connection)
                    self.subscribers[key] = connection
                    if wantsState { self.stateSubscribers[key] = connection }
                    if params?.notifications ?? false { self.notificationSubscribers[key] = connection }
                }
                return SubscribeResult(status: self.status(), state: wantsState ? self.snapshot() : nil)
            }
        case .adopt:
            guard let onAdopt else {
                return Self.failure(id: id, RPCError(code: RPCError.refused, message: "\(holder) wasn't started on demand"))
            }
            return await reply(line, id, AdoptParams.self) { params in
                guard let params else { throw Self.missingParams }
                self.exitsWith = params.exitWith
                self.idleExitSeconds = nil
                self.runtime.ownsAutomation = true
                onAdopt(params.exitWith)
                // Picks up the review requests it left alone until now.
                self.runtime.poller.pollNow()
                return APIEmpty()
            }
        case .shutdown:
            guard let onShutdown else {
                return Self.failure(id: id, RPCError(code: RPCError.refused, message: "\(holder) does not shut down on request"))
            }
            // After the reply is on its way, so the client hears back.
            Task { @MainActor in onShutdown() }
            return await reply(line, id, APIEmpty.self) { _ in APIEmpty() }
        case .event, .state, .notify:
            return nil
        }
    }

    /// Why an agent may not call `method`, or nil when it may.
    nonisolated static func denial(of method: APIMethod, by client: HelloParams, under policy: AgentPolicy) -> RPCError? {
        let capability: AgentPolicy.Capability
        switch method {
        case .hello, .event, .state, .notify:
            return nil
        case .status, .inbox, .refreshPR, .review, .reviewOutcome, .explainRules, .historyActions, .historyReviews, .poll, .subscribe, .fullReview,
             .loadDiff, .invalidateDiff, .loadCILog, .invalidateCILog:
            capability = .read
        case .runReview, .reviewLocal:
            capability = .review
        case .enqueueAction, .retryAction, .dismissAction:
            // Post or merge depends on the action, so the handler decides
            // with `denial(of:under:)` once it knows which action it is.
            return nil
        case .shutdown, .adopt:
            return RPCError(code: RPCError.notPermitted, message: "coding agents can't stop or adopt the PRBar server")
        case .autoReviewUndo, .autoReviewPostNow, .autoReviewDismissFlagged, .setPreferences, .checkoutUsage, .checkoutPrune,
             .setConfig, .clearReviewHistory, .setPopoverVisible, .reportHistoryImport, .reloadHistory:
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

    private func isAgent(_ connection: (any APIConnection)?) -> Bool {
        guard let connection else { return false }
        return clients[ObjectIdentifier(connection)]?.agent == true
    }

    /// Retrying or dismissing a queued write needs the capability of that
    /// write: retrying a failed merge is merging.
    private func authorizeAgent(_ connection: (any APIConnection)?, onActionFor prNodeId: String) throws {
        guard isAgent(connection) else { return }
        guard let entry = runtime.actionQueue.entries[prNodeId] else {
            throw RPCError(code: RPCError.notFound, message: "no queued action for that PR")
        }
        if let denial = Self.denial(of: entry.action.kind, under: runtime.repoConfigs.config.agents) {
            throw denial
        }
    }

    /// Why an agent's review request is refused, or nil to queue it. The
    /// repo's own opt-outs hold even with `force`: they are the user's cost
    /// decision, not a gate the agent may lift. The rest refuse with their
    /// reason unless `force` is set.
    nonisolated private static func isRule(_ reason: ReviewState.SkipReason) -> Bool {
        if case .rule = reason { return true }
        return false
    }

    nonisolated static func agentReviewRefusal(
        pr: InboxPR, config: ResolvedRepoConfig, existing: ReviewState?, force: Bool
    ) -> RPCError? {
        func refused(_ message: String) -> RPCError { RPCError(code: RPCError.refused, message: message) }
        if config.excluded {
            return refused("\(pr.nameWithOwner) is excluded from PRBar in prbar.yaml.")
        }
        switch ReviewAdmission.evaluate(pr: pr, config: config, existing: existing, requireRequested: false, trigger: .agent) {
        case .review:
            return nil
        case .skip(let reason) where reason == .aiReviewDisabled || reason == .titleExcluded:
            return refused("\(reason.detail) Coding agents can't override that; the user can in prbar.yaml.")
        case .skip(let reason) where Self.isRule(reason):
            return refused("\(reason.detail) Coding agents can't override a rule; the user can in the rules directory.")
        case .skip(let reason):
            return force ? nil : refused("Not reviewed: \(reason.detail) Pass force true to review it anyway.")
        case .ignore(.failedAtCurrentSha):
            return force ? nil : refused("PRBar's review of this commit failed. Pass force true to try again, or push a new commit.")
        case .ignore(.notRequested):
            return nil
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
            configWarnings: runtime.repoConfigs.warnings,
            agents: runtime.repoConfigs.config.agents,
            idleExitSeconds: idleExitSeconds,
            rulesPath: runtime.repoConfigs.rulesURL.path,
            rules: runtime.repoConfigs.config.compiledRules.map { RuleCounts(select: $0.select.count, decide: $0.decide.count) },
            rulesIssue: runtime.repoConfigs.rulesIssue
        )
    }

    /// Whether nothing is going on that exiting would cut short: no client,
    /// no review queued or running, no post staged or being written.
    var isIdle: Bool {
        !hasClients
            && !runtime.queue.reviews.values.contains { $0.status.isInFlight }
            && runtime.queue.pendingAutoActions.isEmpty
            && !runtime.actionQueue.entries.values.contains { $0.state.isBusy }
    }

    /// A reference by `path` names the checkout's review slot.
    nonisolated static func resolvingPath(_ ref: PRReference) async throws -> PRReference {
        guard let path = ref.path else { return ref }
        return PRReference(nodeId: LocalChanges.Snapshot.nodeId(root: try await LocalChanges.root(of: path)))
    }

    func explanation(of pr: InboxPR) -> RulesExplanation {
        let config = runtime.repoConfigs.resolve(owner: pr.owner, repo: pr.repo)
        let existing = runtime.queue.reviews[pr.nodeId]
        var select = config.rules.map {
            $0.explainSelect(SelectFacts(pr: ChangeFacts(pr), trigger: .reviewRequested, viewer: pr.viewerLogin, lists: $0.lists))
        } ?? "No rules in \(runtime.repoConfigs.rulesURL.path); the repo settings in prbar.yaml decide."
        select += "\n\nOutcome: " + Self.describe(ReviewAdmission.evaluate(pr: pr, config: config, existing: existing))

        var decide: String?
        if let existing, existing.headSha == pr.headSha, case .completed(let review) = existing.status {
            let rules = config.rules.map {
                $0.explainDecide(DecideFacts(
                    pr: ChangeFacts(pr), review: ReviewFacts(review, provider: existing.providerId),
                    viewer: pr.viewerLogin, lists: $0.lists))
            } ?? "No rules; the repo settings in prbar.yaml decide."
            let outcome = AutoReviewPlan.plan(pr: pr, review: review, config: config, providerId: existing.providerId, diffText: "")
            decide = rules + "\n\nOutcome: " + Self.describe(outcome)
        }
        return RulesExplanation(pr: pr, select: select, decide: decide)
    }

    nonisolated static func describe(_ decision: ReviewAdmission.Decision) -> String {
        switch decision {
        case .review: return "reviewed."
        case .skip(let reason): return "skipped. \(reason.detail)"
        case .ignore(.notRequested): return "not reviewed on its own: you aren't a requested reviewer."
        case .ignore(.failedAtCurrentSha): return "not reviewed again: the review of this commit failed."
        }
    }

    nonisolated static func describe(_ outcome: AutoReviewPlan.Outcome) -> String {
        switch outcome {
        case .none(let reason): return "nothing posted (\(reason))."
        case .flag: return "flagged in PRBar, nothing posted."
        case .post(let staged):
            let kind = staged.source == .sharedFindings ? "the findings, as a comment" : staged.action?.rawValue ?? "nothing"
            return "posts \(kind)."
        }
    }

    /// How events and logs name a PR, or a checkout for a local review.
    nonisolated static func displayName(_ pr: InboxPR) -> String {
        pr.local?.root ?? "\(pr.nameWithOwner)#\(pr.number)"
    }

    private func resolvePR(_ ref: PRReference, fetch: Bool) async throws -> InboxPR {
        if fetch, let owner = ref.owner, let repo = ref.repo, let number = ref.number {
            let pr = try await runtime.poller.fetchPR(owner: owner, repo: repo, number: number)
            if !runtime.poller.prs.contains(where: { $0.nodeId == pr.nodeId }) { fetched[pr.nodeId] = pr }
            return pr
        }
        guard let pr = findPR(ref) else {
            throw RPCError(code: RPCError.notFound, message: "no such PR in the inbox")
        }
        return pr
    }

    /// Queues `pr` for review, or says why not when nothing gets recorded
    /// for it. `gated` applies what an incoming review request meets: the
    /// worker's own gates, plus the request itself.
    private func queueReview(_ pr: InboxPR, config: ResolvedRepoConfig, params: RunReviewParams) -> String? {
        let queue = runtime.queue
        if config.excluded {
            return "\(pr.nameWithOwner) is excluded by config"
        }
        guard params.gated ?? false, !(params.force ?? false) else {
            queue.enqueue(pr, force: params.force ?? false, providerOverride: params.provider)
            return nil
        }
        switch ReviewAdmission.evaluate(pr: pr, config: config, existing: queue.reviews[pr.nodeId], trigger: .command) {
        case .ignore(.notRequested):
            return "no review request for the authenticated user (pass --force to review anyway)"
        case .ignore(.failedAtCurrentSha):
            return "PRBar's review of this commit already failed (pass --force to try again)"
        case .review, .skip:
            queue.enqueueNewReviewRequests(from: [pr], providerOverride: params.provider, trigger: .command)
            return nil
        }
    }

    func outcome(of pr: InboxPR, since: Date) -> ReviewOutcome {
        let state = runtime.queue.reviews[pr.nodeId]
        let staged = runtime.queue.pendingAutoActions[pr.nodeId] != nil
        let writing = runtime.actionQueue.entries[pr.nodeId]?.state.isBusy ?? false
        return ReviewOutcome(
            pr: pr,
            review: state,
            settled: !(state?.status.isInFlight ?? false) && !staged && !writing,
            flagged: runtime.queue.flaggedDenials[pr.nodeId] != nil,
            actions: runtime.actionLog.entries.filter { $0.prNodeId == pr.nodeId && $0.timestamp >= since }.reversed())
    }

    nonisolated static func matches(_ owner: String, _ repo: String, _ number: Int, _ ref: PRReference) -> Bool {
        guard let refOwner = ref.owner, let refRepo = ref.repo, let refNumber = ref.number else { return false }
        return owner.caseInsensitiveCompare(refOwner) == .orderedSame
            && repo.caseInsensitiveCompare(refRepo) == .orderedSame
            && number == refNumber
    }

    private func findPR(_ ref: PRReference) -> InboxPR? {
        let prs = runtime.poller.prs + fetched.values
        if let nodeId = ref.nodeId { return prs.first { $0.nodeId == nodeId } }
        return prs.first { Self.matches($0.owner, $0.repo, $0.number, ref) }
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
