import Foundation

enum APIClientError: Error, LocalizedError, Equatable {
    /// Nothing is listening on the socket.
    case noServer(String)
    case disconnected
    /// The two sides share no protocol version.
    case incompatible(String)

    var errorDescription: String? {
        switch self {
        case .noServer(let path):
            return "no PRBar server is running (nothing listening on \(path)). Start PRBar.app or `prbar-review serve`."
        case .disconnected:
            return "the PRBar server closed the connection"
        case .incompatible(let detail):
            return detail
        }
    }
}

/// One connection to the PRBar server. Requests may be in flight
/// concurrently; replies are matched to them by id. Events arrive on
/// `events` once `subscribe` has been called.
final class APIClient: @unchecked Sendable {
    let events: AsyncStream<APIEvent>
    /// State updates, once subscribed with `state: true`.
    let stateUpdates: AsyncStream<StateUpdate>
    /// Notification batches, once subscribed with `notifications: true`.
    let notifications: AsyncStream<NotificationBatch>

    private let connection: any APIClientTransport
    private let eventSink: AsyncStream<APIEvent>.Continuation
    private let stateSink: AsyncStream<StateUpdate>.Continuation
    private let notificationSink: AsyncStream<NotificationBatch>.Continuation
    private let lock = NSLock()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    /// Replies to `post`s, which nobody awaits.
    private var detached: [Int: @Sendable (Data?) -> Void] = [:]
    private var isClosed = false

    init(transport: any APIClientTransport) {
        self.connection = transport
        (events, eventSink) = AsyncStream<APIEvent>.makeStream()
        (stateUpdates, stateSink) = AsyncStream<StateUpdate>.makeStream(bufferingPolicy: .unbounded)
        (notifications, notificationSink) = AsyncStream<NotificationBatch>.makeStream()
        transport.start(
            onLine: { [weak self] line in self?.receive(line) },
            onClose: { [weak self] in self?.failAll() }
        )
    }

    static func connect(socketURL: URL) throws -> APIClient {
        do {
            return APIClient(transport: LineConnection(fd: try UnixSocket.connect(path: socketURL.path)))
        } catch let error as UnixSocketError where error.isNoListener {
            throw APIClientError.noServer(socketURL.path)
        }
    }

    func call<P: Codable & Sendable, R: Codable & Sendable>(
        _ method: APIMethod, _ params: P, as _: R.Type = R.self
    ) async throws -> R {
        let id = lock.withLock {
            defer { nextId += 1 }
            return nextId
        }
        let line = try RPCLine.encode(RPCRequest(id: id, method: method.rawValue, params: params))
        let reply: Data = try await withCheckedThrowingContinuation { continuation in
            let closed = lock.withLock {
                if isClosed { return true }
                pending[id] = continuation
                return false
            }
            if closed {
                continuation.resume(throwing: APIClientError.disconnected)
            } else if !connection.send(line) {
                if let waiting = lock.withLock({ pending.removeValue(forKey: id) }) {
                    waiting.resume(throwing: APIClientError.disconnected)
                }
            }
        }
        let response = try RPCLine.decode(RPCResponse<R>.self, from: reply)
        if let error = response.error { throw error }
        guard let result = response.result else {
            throw RPCError(code: RPCError.internalError, message: "\(method.rawValue): empty result")
        }
        return result
    }

    func call<R: Codable & Sendable>(_ method: APIMethod, as type: R.Type = R.self) async throws -> R {
        try await call(method, APIEmpty(), as: type)
    }

    /// Sends a request now, on the caller's thread, without waiting for the
    /// reply. Requests posted one after another reach the server in that
    /// order, which separate `call`s from separate tasks don't promise
    /// (invalidate-then-load must not arrive as load-then-invalidate).
    /// `onFailure` gets the server's error, or `disconnected`.
    func post<P: Codable & Sendable>(
        _ method: APIMethod, _ params: P, onFailure: (@Sendable (Error) -> Void)? = nil
    ) {
        post(method, params, as: APIEmpty.self) { result in
            if case .failure(let error) = result { onFailure?(error) }
        }
    }

    /// `post` with the reply decoded. `completion` runs on the connection's
    /// read thread.
    func post<P: Codable & Sendable, R: Codable & Sendable>(
        _ method: APIMethod, _ params: P, as _: R.Type,
        completion: @escaping @Sendable (Result<R, Error>) -> Void
    ) {
        let id = lock.withLock {
            defer { nextId += 1 }
            return nextId
        }
        guard let line = try? RPCLine.encode(RPCRequest(id: id, method: method.rawValue, params: params)) else { return }
        let registered = lock.withLock {
            if isClosed { return false }
            detached[id] = { reply in
                guard let reply else {
                    completion(.failure(APIClientError.disconnected))
                    return
                }
                do {
                    let response = try RPCLine.decode(RPCResponse<R>.self, from: reply)
                    if let error = response.error { throw error }
                    guard let result = response.result else {
                        throw RPCError(code: RPCError.internalError, message: "\(method.rawValue): empty result")
                    }
                    completion(.success(result))
                } catch {
                    completion(.failure(error))
                }
            }
            return true
        }
        guard registered else {
            completion(.failure(APIClientError.disconnected))
            return
        }
        if !connection.send(line) {
            lock.withLock { detached.removeValue(forKey: id) }?(nil)
        }
    }

    func close() {
        connection.close()
    }

    private func receive(_ line: Data) {
        guard let header = try? RPCLine.decode(RPCHeader.self, from: line) else { return }
        if let id = header.id, header.method == nil {
            let (waiter, handler) = lock.withLock {
                (pending.removeValue(forKey: id), detached.removeValue(forKey: id))
            }
            waiter?.resume(returning: line)
            handler?(line)
        } else if header.method == APIMethod.event.rawValue,
                  let event = try? RPCLine.decode(RPCRequest<APIEvent>.self, from: line).params {
            eventSink.yield(event)
        } else if header.method == APIMethod.state.rawValue,
                  let update = try? RPCLine.decode(RPCRequest<StateUpdate>.self, from: line).params {
            stateSink.yield(update)
        } else if header.method == APIMethod.notify.rawValue,
                  let batch = try? RPCLine.decode(RPCRequest<NotificationBatch>.self, from: line).params {
            notificationSink.yield(batch)
        }
    }

    private func failAll() {
        let (waiting, handlers) = lock.withLock {
            isClosed = true
            defer {
                pending.removeAll()
                detached.removeAll()
            }
            return (Array(pending.values), Array(detached.values))
        }
        for continuation in waiting { continuation.resume(throwing: APIClientError.disconnected) }
        for handler in handlers { handler(nil) }
        eventSink.finish()
        stateSink.finish()
        notificationSink.finish()
    }
}

/// How every client reaches the server: connect, then `hello` to agree a
/// protocol version before anything else is sent.
enum ServerConnection {
    struct Connected: Sendable {
        let client: APIClient
        let hello: HelloResult
    }

    static func connect(
        socketURL: URL = ServerLocation.socketURL(),
        client name: String,
        agent: Bool = false
    ) async throws -> Connected {
        let client = try APIClient.connect(socketURL: socketURL)
        let hello: HelloResult
        do {
            hello = try await client.call(
                .hello,
                HelloParams(client: name, protocolVersion: APIVersion.current, agent: agent ? true : nil),
                as: HelloResult.self)
        } catch let error as RPCError where error.code == RPCError.incompatibleVersion {
            client.close()
            throw APIClientError.incompatible("\(error.message); update PRBar so both sides match")
        }
        guard hello.protocolVersions.contains(APIVersion.current) else {
            client.close()
            throw APIClientError.incompatible(
                "the server (\(hello.holder) \(hello.build)) speaks protocol \(APIServer.describe(hello.protocolVersions)), this client \(APIVersion.current); update PRBar so both sides match")
        }
        return Connected(client: client, hello: hello)
    }
}
