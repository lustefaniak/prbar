import XCTest
@testable import PRBarCore

/// A front end talking to a server in another process: the server can go
/// away (a crash, an update) and a new one take its place.
@MainActor
final class SessionReconnectTests: XCTestCase {
    func testSessionReconnectsAndReplaysItsSettings() async throws {
        let dir = URL(fileURLWithPath: "/tmp/prbar-rc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let socketURL = dir.appendingPathComponent("server.sock")

        func serve(_ prs: [InboxPR]) throws -> (PRBarRuntime, APIServer) {
            let runtime = RuntimeFixtures.make(dir.appendingPathComponent(UUID().uuidString), ownsAutomation: false, prs: prs)
            let server = APIServer(runtime: runtime, holder: "test", build: "dev")
            try server.start(socketURL: socketURL)
            return (runtime, server)
        }

        let (firstRuntime, first) = try serve([RuntimeFixtures.requestedPR()])
        firstRuntime.queue._setReviewsForScreenshot([
            "PR_1": ReviewState(prNodeId: "PR_1", headSha: "abc123", triggeredAt: Date(), status: .failed("old"), costUsd: 0),
        ])
        let session = ServerSession(connect: { try await ServerConnection.connect(socketURL: socketURL, client: "tests") })
        session.setPreferences(PreferencesParams(undoWindowSeconds: 12))
        // Before the first connection, as when the history import finishes
        // early: kept and delivered once connected.
        session.reportHistoryImport(.failed("import broke"), finished: true)
        session.run()
        defer { session.stop() }
        try await until { session.inbox.prs.count == 1 }
        XCTAssertEqual(session.connection.isConnected, true)
        XCTAssertNotNil(session.reviews.reviews["PR_1"])
        try await until { firstRuntime.actionLog.importStatus == .failed("import broke") }

        first.stop()
        try await until { !session.connection.isConnected }

        let (second, replacement) = try serve([RuntimeFixtures.requestedPR(), RuntimeFixtures.requestedPR(nodeId: "PR_2", number: 2)])
        defer { replacement.stop() }
        try await until { session.inbox.prs.count == 2 }
        XCTAssertEqual(session.connection.isConnected, true)
        XCTAssertNil(session.reviews.reviews["PR_1"], "state only the old server had is gone after the snapshot")
        try await until { second.queue.undoWindow == 12 }
    }

    private func until(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition())
    }
}

/// Starting a server when none answers, with the real binary.
final class ServerLauncherTests: XCTestCase {
    private func binary() throws -> String {
        // SwiftPM builds the executable next to the test bundle (macOS) or
        // the test runner (Linux).
        let candidates = [
            Bundle(for: Self.self).bundleURL.deletingLastPathComponent(),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent(),
        ].map { $0.appendingPathComponent("prbar-review").path }
        let found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        try XCTSkipUnless(found != nil, "prbar-review not built at any of \(candidates)")
        return found!
    }

    private func scratch() throws -> (dir: URL, socket: URL, environment: [String: String]) {
        let dir = URL(fileURLWithPath: "/tmp/prbar-ls-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try "defaults:\n  aiReviewEnabled: false\n".write(to: dir.appendingPathComponent("prbar.yaml"), atomically: true, encoding: .utf8)
        let state = dir.appendingPathComponent("state")
        return (dir, state.appendingPathComponent("prbar/server.sock"), [
            "XDG_STATE_HOME": state.path,
            "XDG_CACHE_HOME": dir.appendingPathComponent("cache").path,
            "PRBAR_CONFIG": dir.appendingPathComponent("prbar.yaml").path,
        ])
    }

    /// The app's case: a server tied to it, reused while it answers, and
    /// replaced when it comes from another build.
    func testStartsATiedServerAndReplacesOneFromAnotherBuild() async throws {
        let path = try binary()
        let (dir, socketURL, environment) = try scratch()
        let executable = ServerLauncher.Executable(
            path: path, arguments: ["serve", "--exit-with", String(getpid())],
            log: dir.appendingPathComponent("server.log"), environment: environment)

        let first = try await ServerLauncher.connect(socketURL: socketURL, client: "tests", executable: executable)
        XCTAssertEqual(first.hello.holder, ServerLauncher.serveHolder)
        XCTAssertEqual(first.hello.exitsWith, getpid())
        let second = try await ServerLauncher.connect(socketURL: socketURL, client: "tests", executable: executable)
        XCTAssertEqual(second.hello.pid, first.hello.pid, "an answering server is reused, not replaced")
        second.client.close()

        let replaced = try await ServerLauncher.connect(
            socketURL: socketURL, client: "tests", executable: executable, expectedBuild: "some-other-build")
        XCTAssertNotEqual(replaced.hello.pid, first.hello.pid)
        first.client.close()
        _ = try? await replaced.client.call(.shutdown, as: APIEmpty.self)
        replaced.client.close()
    }

    /// A server someone started with `prbar-review serve` is theirs: used
    /// whatever its build, never asked to exit.
    func testLeavesAServerStartedOnPurposeAlone() async throws {
        let path = try binary()
        let (dir, socketURL, environment) = try scratch()
        let explicit = ServerLauncher.Executable(
            path: path, log: dir.appendingPathComponent("explicit.log"), environment: environment)
        let theirs = try await ServerLauncher.connect(socketURL: socketURL, client: "tests", executable: explicit)
        XCTAssertNil(theirs.hello.exitsWith)

        let tied = ServerLauncher.Executable(
            path: path, arguments: ["serve", "--exit-with", String(getpid())],
            log: dir.appendingPathComponent("tied.log"), environment: environment)
        let app = try await ServerLauncher.connect(
            socketURL: socketURL, client: "tests", executable: tied, expectedBuild: "some-other-build")
        XCTAssertEqual(app.hello.pid, theirs.hello.pid)
        app.client.close()
        _ = try? await theirs.client.call(.shutdown, as: APIEmpty.self)
        theirs.client.close()
    }

    /// Tied to a process, the server goes when it does, crash included.
    func testServerExitsWithItsOwner() async throws {
        let path = try binary()
        let (dir, socketURL, environment) = try scratch()
        let owner = Process()
        owner.executableURL = URL(fileURLWithPath: "/bin/sleep")
        owner.arguments = ["60"]
        try owner.run()
        let executable = ServerLauncher.Executable(
            path: path, arguments: ["serve", "--exit-with", String(owner.processIdentifier)],
            log: dir.appendingPathComponent("server.log"), environment: environment)
        let connected = try await ServerLauncher.connect(socketURL: socketURL, client: "tests", executable: executable)
        let serverPid = connected.hello.pid
        connected.client.close()

        owner.terminate()
        owner.waitUntilExit()
        for _ in 0..<100 where ServeCommand.isRunning(serverPid) {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(ServeCommand.isRunning(serverPid), "server still running after its owner exited")
    }
}
