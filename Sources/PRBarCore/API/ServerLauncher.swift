import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Reaches the PRBar server, starting one when nothing answers: the
/// `ensureServer` of the client-server design. Starting is safe to race:
/// a server takes the runtime lock before binding the socket, so of two
/// started at once one exits and both clients connect to the other.
enum ServerLauncher {
    /// How `prbar-review serve` introduces itself in `hello`.
    static let serveHolder = "prbar-review serve"

    struct Executable: Sendable {
        var path: String
        var arguments: [String] = ["serve"]
        /// Where the started server's stderr goes.
        var log: URL
        /// Set on top of this process's environment.
        var environment: [String: String] = [:]
    }

    enum LaunchError: Error, LocalizedError {
        case spawn(String, Int32)
        case noAnswer(String)

        var errorDescription: String? {
            switch self {
            case .spawn(let path, let code):
                return "could not start \(path): \(String(cString: strerror(code)))"
            case .noAnswer(let log):
                return "the PRBar server was started but never answered; see \(log)"
            }
        }
    }

    /// Connects, starting `executable` first when nobody listens. With
    /// `expectedBuild`, a server of ours from another build (the old one,
    /// still running after an update) is asked to exit and replaced.
    static func connect(
        socketURL: URL,
        client: String,
        executable: Executable,
        expectedBuild: String? = nil,
        holder: String = serveHolder,
        timeout: Duration = .seconds(15)
    ) async throws -> ServerConnection.Connected {
        do {
            let connected = try await ServerConnection.connect(socketURL: socketURL, client: client)
            guard let expectedBuild, connected.hello.build != expectedBuild, connected.hello.holder == holder else {
                return connected
            }
            PRBarLog.lifecycle.notice("server build \(connected.hello.build, privacy: .public) is not \(expectedBuild, privacy: .public); restarting it")
            _ = try? await connected.client.call(.shutdown, as: APIEmpty.self)
            connected.client.close()
            try await waitUntilGone(socketURL: socketURL, timeout: .seconds(10))
        } catch APIClientError.noServer {
            // Nobody there: start one below. Any other failure, an
            // incompatible server included, is thrown: a server we can't
            // talk to can't be asked to exit either, and one started now
            // would only lose the lock to it.
        }
        try spawn(executable)
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let connected = try? await ServerConnection.connect(socketURL: socketURL, client: client) {
                return connected
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LaunchError.noAnswer(executable.log.path)
    }

    private static func waitUntilGone(socketURL: URL, timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            do {
                let probe = try APIClient.connect(socketURL: socketURL)
                probe.close()
            } catch {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Starts `executable` in a session of its own, so it outlives the
    /// caller and a Ctrl-C in the caller's terminal doesn't reach it.
    static func spawn(_ executable: Executable) throws {
        try? FileManager.default.createDirectory(
            at: executable.log.deletingLastPathComponent(), withIntermediateDirectories: true)

        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, executable.log.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        posix_spawnattr_setflags(&attributes, Int16(setsidFlag))

        let argv = ([executable.path] + executable.arguments).map { strdup($0) } + [nil]
        let env = ProcessInfo.processInfo.environment.merging(executable.environment) { _, new in new }
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
        guard result == 0 else { throw LaunchError.spawn(executable.path, result) }
        PRBarLog.lifecycle.notice("started PRBar server pid \(pid, privacy: .public)")
    }

    #if canImport(Darwin)
    private static let setsidFlag = Int32(POSIX_SPAWN_SETSID)
    #else
    // glibc's POSIX_SPAWN_SETSID (2.26+), not always visible to Swift.
    private static let setsidFlag: Int32 = 0x80
    #endif
}
