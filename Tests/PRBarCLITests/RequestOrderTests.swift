import XCTest
@testable import PRBarCore

/// One client's requests are handled in the order it sent them. The UI
/// relies on it: "Reload diff" is invalidate then load, and a burst of
/// config writes must end on the last one.
@MainActor
final class RequestOrderTests: XCTestCase {
    private func makeServer() throws -> (APIServer, URL) {
        let dir = URL(fileURLWithPath: "/tmp/prbar-ord-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let runtime = RuntimeFixtures.make(dir, ownsAutomation: false)
        let server = APIServer(runtime: runtime, holder: "test", build: "dev")
        addTeardownBlock { @MainActor in server.stop() }
        return (server, dir.appendingPathComponent("server.sock"))
    }

    /// The first request is slow to handle; the second must still wait.
    private func assertHandledInOrder(_ server: APIServer, _ client: APIClient) async throws {
        var handled: [APIMethod] = []
        var first = true
        server._beforeHandling = { method in
            guard method != .hello else { return }
            if first {
                first = false
                try? await Task.sleep(for: .milliseconds(200))
            }
            handled.append(method)
        }
        client.post(.poll, APIEmpty())
        client.post(.status, APIEmpty())
        for _ in 0..<100 where handled.count < 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(handled, [.poll, .status])
    }

    func testSocketConnectionHandlesRequestsInOrder() async throws {
        let (server, socket) = try makeServer()
        try server.start(socketURL: socket)
        let client = try await ServerConnection.connect(socketURL: socket, client: "tests").client
        defer { client.close() }
        try await assertHandledInOrder(server, client)
    }

    func testInProcessConnectionHandlesRequestsInOrder() async throws {
        let (server, _) = try makeServer()
        let client = server.connectInProcess()
        defer { client.close() }
        try await assertHandledInOrder(server, client)
    }
}
