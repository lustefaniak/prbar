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
        let poller = runtime.poller
        trackers = [
            StateTracker(read: { poller.prs }) { [weak self] prs in
                self?.publish(StateUpdate(prs: prs))
            },
            StateTracker(read: { Self.polling(poller) }) { [weak self] polling in
                self?.publish(StateUpdate(polling: polling))
            },
        ]
    }

    /// Everything a front end renders, for a new state subscriber.
    func snapshot() -> StateUpdate {
        StateUpdate(prs: runtime.poller.prs, polling: Self.polling(runtime.poller))
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
            return reply(line, id, HelloParams.self) { params in
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
            return reply(line, id, APIEmpty.self) { _ in self.status() }
        case .inbox:
            return reply(line, id, APIEmpty.self) { _ in self.runtime.poller.prs }
        case .refreshPR:
            return reply(line, id, RefreshParams.self) { params in
                guard let params, let pr = self.findPR(params.pr) else {
                    throw RPCError(code: RPCError.notFound, message: "no such PR in the inbox")
                }
                self.runtime.poller.refreshPR(pr, force: params.force ?? false)
                return APIEmpty()
            }
        case .review:
            return reply(line, id, PRReference.self) { ref in
                guard let ref, let pr = self.findPR(ref) else {
                    throw RPCError(code: RPCError.notFound, message: "no such PR in the inbox")
                }
                return ReviewResult(pr: pr, review: self.runtime.queue.reviews[pr.nodeId])
            }
        case .runReview:
            return reply(line, id, RunReviewParams.self) { params in
                guard let params, let pr = self.findPR(params.pr) else {
                    throw RPCError(code: RPCError.notFound, message: "no such PR in the inbox")
                }
                self.runtime.queue.enqueue(pr, force: params.force ?? false)
                return ReviewResult(pr: pr, review: self.runtime.queue.reviews[pr.nodeId])
            }
        case .historyActions:
            return reply(line, id, HistoryParams.self) { params in
                Self.limited(self.runtime.actionLog.entries, params?.limit)
            }
        case .historyReviews:
            return reply(line, id, HistoryParams.self) { params in
                Self.limited(self.runtime.reviewLog.entries, params?.limit)
            }
        case .poll:
            return reply(line, id, APIEmpty.self) { _ in
                self.runtime.poller.pollNow()
                return APIEmpty()
            }
        case .subscribe:
            return reply(line, id, SubscribeParams.self) { params in
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
            return reply(line, id, APIEmpty.self) { _ in APIEmpty() }
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
        case .status, .inbox, .refreshPR, .review, .historyActions, .historyReviews, .poll, .subscribe:
            capability = .read
        case .runReview:
            capability = .review
        case .shutdown:
            return RPCError(code: RPCError.notPermitted, message: "coding agents can't stop the PRBar server")
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
        _ line: Data, _ id: Int?, _: P.Type, _ body: (P?) throws -> R
    ) -> Data? {
        let params: P?
        do {
            params = try RPCLine.decode(RPCRequest<P>.self, from: line).params
        } catch {
            return Self.failure(id: id, RPCError(code: RPCError.invalidParams, message: "invalid params: \(error)"))
        }
        do {
            let result = try body(params)
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
