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

    private let connection: LineConnection
    private let eventSink: AsyncStream<APIEvent>.Continuation
    private let lock = NSLock()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var isClosed = false

    init(connection: LineConnection) {
        self.connection = connection
        (events, eventSink) = AsyncStream<APIEvent>.makeStream()
        connection.startReading(
            onLine: { [weak self] line in self?.receive(line) },
            onClose: { [weak self] in self?.failAll() }
        )
    }

    static func connect(socketURL: URL) throws -> APIClient {
        do {
            return APIClient(connection: LineConnection(fd: try UnixSocket.connect(path: socketURL.path)))
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

    func close() {
        connection.close()
    }

    private func receive(_ line: Data) {
        guard let header = try? RPCLine.decode(RPCHeader.self, from: line) else { return }
        if let id = header.id, header.method == nil {
            lock.withLock { pending.removeValue(forKey: id) }?.resume(returning: line)
        } else if header.method == APIMethod.event.rawValue,
                  let event = try? RPCLine.decode(RPCRequest<APIEvent>.self, from: line).params {
            eventSink.yield(event)
        }
    }

    private func failAll() {
        let waiting = lock.withLock {
            isClosed = true
            defer { pending.removeAll() }
            return Array(pending.values)
        }
        for continuation in waiting { continuation.resume(throwing: APIClientError.disconnected) }
        eventSink.finish()
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
