import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum UnixSocketError: Error, LocalizedError, Equatable {
    case pathTooLong(String)
    case system(String, Int32)

    var errorDescription: String? {
        switch self {
        case .pathTooLong(let path):
            return "socket path is too long for a Unix socket: \(path)"
        case .system(let call, let code):
            return "\(call): \(String(cString: strerror(code)))"
        }
    }

    /// Nobody is listening: no file, or a file left behind by a server
    /// that exited.
    var isNoListener: Bool {
        if case .system(_, let code) = self { return code == ENOENT || code == ECONNREFUSED }
        return false
    }
}

/// Plain POSIX stream sockets on a filesystem path, the same code on macOS
/// and Linux. No Network.framework (macOS only) and no NIO (a large
/// dependency for one local socket).
enum UnixSocket {
    static func listen(path: String) throws -> Int32 {
        var addr = try address(path)
        let fd = socket(AF_UNIX, streamType, 0)
        guard fd >= 0 else { throw UnixSocketError.system("socket", errno) }
        // The caller holds the runtime lock, so a file here is a socket
        // left by a server that died: nobody else can be bound to it.
        unlink(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw UnixSocketError.system("bind \(path)", code)
        }
        // Filesystem permissions are the authentication: only this user
        // may connect. Nobody can connect before `listen`, so there is no
        // window, but a socket that stays open to others must not serve.
        guard chmod(path, 0o600) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw UnixSocketError.system("chmod \(path)", code)
        }
        guard sys_listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw UnixSocketError.system("listen", code)
        }
        return fd
    }

    static func connect(path: String) throws -> Int32 {
        var addr = try address(path)
        let fd = socket(AF_UNIX, streamType, 0)
        guard fd >= 0 else { throw UnixSocketError.system("socket", errno) }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sys_connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let code = errno
            close(fd)
            throw UnixSocketError.system("connect \(path)", code)
        }
        noSigPipe(fd)
        return fd
    }

    /// Waits up to `timeoutMs` for a connection. Nil on timeout, so an
    /// accept loop can check whether it should stop: closing a listening
    /// socket doesn't reliably wake a blocked `accept` on macOS.
    static func accept(_ listener: Int32, timeoutMs: Int32) -> Int32? {
        var pfd = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, timeoutMs) > 0 else { return nil }
        let fd = sys_accept(listener, nil, nil)
        guard fd >= 0 else { return nil }
        noSigPipe(fd)
        return fd
    }

    /// Writes all of `data`. False once the peer has gone.
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let n = send(fd, base + offset, raw.count - offset, sendFlags)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw UnixSocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        #if canImport(Darwin)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        return addr
    }

    // A write to a socket whose peer has gone raises SIGPIPE, which kills
    // the process by default. macOS opts out per socket, Linux per send.
    private static func noSigPipe(_ fd: Int32) {
        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    #if canImport(Darwin)
    private static let streamType = SOCK_STREAM
    private static let sendFlags: Int32 = 0
    #else
    private static let streamType = Int32(SOCK_STREAM.rawValue)
    private static let sendFlags = Int32(MSG_NOSIGNAL)
    #endif
}

// `listen`, `connect` and `accept` are shadowed by the static methods
// above inside `UnixSocket`; these reach the C functions.
private func sys_listen(_ fd: Int32, _ backlog: Int32) -> Int32 {
    listen(fd, backlog)
}

private func sys_connect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
    connect(fd, addr, len)
}

private func sys_accept(_ fd: Int32, _ addr: UnsafeMutablePointer<sockaddr>?, _ len: UnsafeMutablePointer<socklen_t>?) -> Int32 {
    accept(fd, addr, len)
}

/// One connected socket carrying newline-delimited messages. Reads on a
/// thread of its own and hands each complete line to `onLine`; writes are
/// serialised so two senders can't interleave a line.
final class LineConnection: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var isClosed = false
    private var isReading = false

    init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        close()
    }

    /// Sends one message. False when the connection is closed.
    @discardableResult
    func send(_ line: Data) -> Bool {
        var framed = line
        framed.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return false }
        return UnixSocket.writeAll(fd, framed)
    }

    /// Starts the read thread. `onClose` runs once, after the last line,
    /// when the peer hangs up or `close()` is called.
    func startReading(onLine: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        lock.lock()
        isReading = true
        lock.unlock()
        let fd = self.fd
        let thread = Thread { [self] in
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            readLoop: while true {
                let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { break }
                buffer.append(contentsOf: chunk[0..<n])
                while let newline = buffer.firstIndex(of: 0x0A) {
                    // Copied out before the buffer is trimmed: a slice
                    // shares storage with it.
                    let line = Data(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if !line.isEmpty { onLine(line) }
                }
                if buffer.count > 64 * 1024 * 1024 { break readLoop }
            }
            self.finishReading()
            onClose()
        }
        thread.name = "prbar-api-read"
        thread.start()
    }

    /// Hangs up. Wakes the read thread, which then releases the socket.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        shutdown(fd, Int32(SHUT_RDWR))
        if !isReading { sys_close(fd) }
    }

    private func finishReading() {
        lock.lock()
        defer { lock.unlock() }
        if !isClosed {
            isClosed = true
            shutdown(fd, Int32(SHUT_RDWR))
        }
        isReading = false
        sys_close(fd)
    }
}

private func sys_close(_ fd: Int32) {
    _ = close(fd)
}
