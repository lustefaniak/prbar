import XCTest
@testable import PRBarCore

final class ClientCommandTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(ClientCommand(args: ["status"]), .status(json: false))
        XCTAssertEqual(ClientCommand(args: ["status", "--json"]), .status(json: true))
        XCTAssertEqual(ClientCommand(args: ["inbox"]), .inbox(json: false))
        XCTAssertEqual(ClientCommand(args: ["history"]), .history(kind: .actions, limit: 20, json: false))
        XCTAssertEqual(ClientCommand(args: ["history", "reviews", "--limit", "5"]), .history(kind: .reviews, limit: 5, json: false))
        // --json means "all of it" unless a limit is given.
        XCTAssertEqual(ClientCommand(args: ["history", "--json"]), .history(kind: .actions, limit: nil, json: true))
        XCTAssertEqual(ClientCommand(args: ["events"]), .events)

        XCTAssertNil(ClientCommand(args: ["status", "--help"]))
        XCTAssertNil(ClientCommand(args: ["status", "extra"]))
        XCTAssertNil(ClientCommand(args: ["history", "merges"]))
        XCTAssertNil(ClientCommand(args: ["history", "--limit", "0"]))
        XCTAssertNil(ClientCommand(args: ["events", "--json"]))
    }

    func testStatusText() {
        let started = Date(timeIntervalSince1970: 1_000_000)
        var status = ServerStatus(
            holder: "PRBar.app", build: "0.15.0 (612)", pid: 42, startedAt: started,
            ownsAutomation: true, lastPollAt: started.addingTimeInterval(7200), lastPollError: nil,
            prCount: 26, awaitingReview: 3, reviewsQueued: 2, reviewsRunning: 1,
            configPath: "/home/u/.config/prbar/prbar.yaml", configIssue: nil, configWarnings: [])
        let text = ClientCommand.describe(status, now: started.addingTimeInterval(7240))
        XCTAssertTrue(text.contains("server:     PRBar.app, build 0.15.0 (612), pid 42, up 2h 0m"), text)
        XCTAssertTrue(text.contains("(40s ago), 26 PRs, 3 awaiting your review"), text)
        XCTAssertTrue(text.contains("reviews:    1 running, 2 queued"), text)
        XCTAssertFalse(text.contains("problem:"))

        status.lastPollError = "gh: not logged in"
        status.configWarnings = ["unknown key: defaults.typo"]
        let degraded = ClientCommand.describe(status, now: started.addingTimeInterval(7240))
        XCTAssertTrue(degraded.contains("problem:    last poll failed: gh: not logged in"), degraded)
        XCTAssertTrue(degraded.contains("warning:    unknown key: defaults.typo"), degraded)
    }

    /// Exit status is what scripts check: 3 when nothing is listening, 0
    /// against a healthy server, 1 once it reports a problem.
    @MainActor
    func testExitStatusAgainstARealServer() async throws {
        let dir = URL(fileURLWithPath: "/tmp/prbar-cli-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let socketURL = dir.appendingPathComponent("server.sock")

        let missing = await ClientCommand.status(json: true).run(socketURL: socketURL)
        XCTAssertEqual(missing, 3)

        let runtime = RuntimeFixtures.make(dir, ownsAutomation: true)
        let server = APIServer(runtime: runtime, holder: "test")
        try server.start(socketURL: socketURL)
        defer { server.stop() }
        let healthy = await ClientCommand.status(json: true).run(socketURL: socketURL)
        XCTAssertEqual(healthy, 0)
        let history = await ClientCommand.history(kind: .reviews, limit: 1, json: true).run(socketURL: socketURL)
        XCTAssertEqual(history, 0)

        try "repos: [unclosed".write(to: dir.appendingPathComponent("prbar.yaml"), atomically: true, encoding: .utf8)
        runtime.repoConfigs.reloadIfChanged()
        let degraded = await ClientCommand.status(json: true).run(socketURL: socketURL)
        XCTAssertEqual(degraded, 1)
    }
}
