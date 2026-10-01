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

        let (_, first) = try serve([RuntimeFixtures.requestedPR()])
        let session = ServerSession(connect: { try await ServerConnection.connect(socketURL: socketURL, client: "tests") })
        session.setPreferences(PreferencesParams(undoWindowSeconds: 12))
        session.run()
        defer { session.stop() }
        try await until { session.inbox.prs.count == 1 }
        XCTAssertEqual(session.connection.isConnected, true)

        first.stop()
        try await until { !session.connection.isConnected }

        let (second, replacement) = try serve([RuntimeFixtures.requestedPR(), RuntimeFixtures.requestedPR(nodeId: "PR_2", number: 2)])
        defer { replacement.stop() }
        try await until { session.inbox.prs.count == 2 }
        XCTAssertEqual(session.connection.isConnected, true)
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
    func testStartsAServerWhenNoneAnswersAndReusesIt() async throws {
        // SwiftPM builds the executable next to the test bundle (macOS) or
        // the test runner (Linux).
        let candidates = [
            Bundle(for: Self.self).bundleURL.deletingLastPathComponent(),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent(),
        ].map { $0.appendingPathComponent("prbar-review").path }
        let found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        try XCTSkipUnless(found != nil, "prbar-review not built at any of \(candidates)")
        let path = found!
        let dir = URL(fileURLWithPath: "/tmp/prbar-ls-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try "defaults:\n  aiReviewEnabled: false\n".write(to: dir.appendingPathComponent("prbar.yaml"), atomically: true, encoding: .utf8)
        let state = dir.appendingPathComponent("state")
        let socketURL = state.appendingPathComponent("prbar/server.sock")
        let executable = ServerLauncher.Executable(
            path: path,
            log: dir.appendingPathComponent("server.log"),
            environment: [
                "XDG_STATE_HOME": state.path,
                "XDG_CACHE_HOME": dir.appendingPathComponent("cache").path,
                "PRBAR_CONFIG": dir.appendingPathComponent("prbar.yaml").path,
            ])

        let first = try await ServerLauncher.connect(socketURL: socketURL, client: "tests", executable: executable)
        XCTAssertEqual(first.hello.holder, ServeCommand.holder)
        let second = try await ServerLauncher.connect(socketURL: socketURL, client: "tests", executable: executable)
        XCTAssertEqual(second.hello.pid, first.hello.pid, "an answering server is reused, not replaced")
        second.client.close()

        // A server from another build is asked to exit and replaced.
        let replaced = try await ServerLauncher.connect(
            socketURL: socketURL, client: "tests", executable: executable, expectedBuild: "some-other-build")
        XCTAssertNotEqual(replaced.hello.pid, first.hello.pid)
        first.client.close()
        _ = try? await replaced.client.call(.shutdown, as: APIEmpty.self)
        replaced.client.close()
    }
}
