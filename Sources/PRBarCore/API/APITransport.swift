import Foundation

/// The server's end of one client connection: where replies and events go.
protocol APIConnection: AnyObject, Sendable {
    /// Sends one message. False once the connection is closed.
    @discardableResult
    func send(_ line: Data) -> Bool
    func close()
}

/// The client's end: carries requests to the server and hands back every
/// line that arrives.
protocol APIClientTransport: AnyObject, Sendable {
    @discardableResult
    func send(_ line: Data) -> Bool
    /// `onClose` runs once, after the last line.
    func start(onLine: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void)
    func close()
}

extension LineConnection: APIConnection {}

extension LineConnection: APIClientTransport {
    func start(onLine: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        startReading(onLine: onLine, onClose: onClose)
    }
}

/// A client and a server in the same process, without a socket in between.
/// Messages are still encoded lines, so the app's own UI speaks exactly the
/// protocol every other client does, and moving the server out of the app
/// later only changes which transport is used.
final class InProcessClientTransport: APIClientTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var onLine: (@Sendable (Data) -> Void)?
    private var onClose: (@Sendable () -> Void)?
    private var isClosed = false
    private let deliver: @Sendable (Data) -> Void

    /// `deliver` hands a request line to the server, which answers through
    /// `serverEnd`.
    init(serverEnd: InProcessServerEnd, deliver: @escaping @Sendable (Data) -> Void) {
        self.deliver = deliver
        serverEnd.client = self
    }

    func send(_ line: Data) -> Bool {
        guard !lock.withLock({ isClosed }) else { return false }
        deliver(line)
        return true
    }

    func start(onLine: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        lock.withLock {
            self.onLine = onLine
            self.onClose = onClose
        }
    }

    func close() {
        let callback: (@Sendable () -> Void)? = lock.withLock {
            guard !isClosed else { return nil }
            isClosed = true
            defer { onClose = nil; onLine = nil }
            return onClose
        }
        callback?()
    }

    /// A line from the server.
    fileprivate func receive(_ line: Data) -> Bool {
        guard let onLine = lock.withLock({ isClosed ? nil : self.onLine }) else { return false }
        onLine(line)
        return true
    }
}

final class InProcessServerEnd: APIConnection, @unchecked Sendable {
    fileprivate weak var client: InProcessClientTransport?

    @discardableResult
    func send(_ line: Data) -> Bool {
        client?.receive(line) ?? false
    }

    func close() {
        client?.close()
    }
}

extension APIServer {
    /// A client connected to this server inside the same process.
    func connectInProcess() -> APIClient {
        let server = self
        let end = InProcessServerEnd()
        let transport = InProcessClientTransport(serverEnd: end) { line in
            Task { @MainActor in
                if let reply = await server.handle(line, from: end) { end.send(reply) }
            }
        }
        register(end)
        return APIClient(transport: transport)
    }
}
