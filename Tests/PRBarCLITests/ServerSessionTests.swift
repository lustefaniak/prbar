import XCTest
@testable import PRBarCore

/// The app's view of the server, over the in-process transport.
@MainActor
final class ServerSessionTests: XCTestCase {
    private func makeServer(prs: [InboxPR]) -> (PRBarRuntime, APIServer) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prbar-session-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let runtime = RuntimeFixtures.make(dir, ownsAutomation: false, prs: prs)
        let server = APIServer(runtime: runtime, holder: "test", build: "dev")
        addTeardownBlock { @MainActor in server.stop() }
        return (runtime, server)
    }

    /// Waits for the main actor to drain the updates already in flight.
    private func until(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition())
    }

    func testSnapshotThenUpdates() async throws {
        let (runtime, server) = makeServer(prs: [RuntimeFixtures.requestedPR()])
        let session = ServerSession(client: server.connectInProcess())
        defer { session.stop() }
        try await session.start()
        XCTAssertEqual(session.inbox.prs.map(\.nodeId), ["PR_1"], "the snapshot arrives with the subscribe reply")
        XCTAssertNotNil(session.inbox.lastFetchedAt)

        runtime.poller._setPRsForScreenshot([RuntimeFixtures.requestedPR(), RuntimeFixtures.requestedPR(nodeId: "PR_2", number: 2)])
        try await until { session.inbox.prs.count == 2 }
    }

    func testCommandsReachTheRuntime() async throws {
        let (runtime, server) = makeServer(prs: [RuntimeFixtures.requestedPR()])
        let session = ServerSession(client: server.connectInProcess())
        defer { session.stop() }
        try await session.start()

        runtime.poller._setPRsForScreenshot([])
        try await until { session.inbox.prs.isEmpty }
        session.inbox.pollNow()
        try await until { session.inbox.prs.map(\.nodeId) == ["PR_1"] }
    }
}
