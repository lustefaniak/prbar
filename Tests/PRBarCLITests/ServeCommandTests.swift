import XCTest
@testable import PRBarCore

final class ServeCommandTests: XCTestCase {
    func testOptionsParse() {
        XCTAssertEqual(ServeCommand.Options(args: [])?.configPath, nil)
        XCTAssertEqual(ServeCommand.Options(args: ["--config", "x.yaml"])?.configPath, "x.yaml")
        XCTAssertEqual(ServeCommand.Options(args: ["--daily-cap", "12.5"])?.dailyCapUsd, 12.5)
        XCTAssertEqual(ServeCommand.Options(args: ["--daily-cap", "off"])?.dailyCapUsd, 0)
        XCTAssertNil(ServeCommand.Options(args: ["--daily-cap", "-1"]))
        XCTAssertNil(ServeCommand.Options(args: ["--config"]))
        XCTAssertNil(ServeCommand.Options(args: ["owner/repo#1"]))
    }

    /// One automating PRBar per state directory: a second holder is
    /// refused until the first releases, and learns who holds it.
    func testRuntimeLockIsExclusive() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prbar-lock-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let first = RuntimeLock(stateDirectory: dir)
        let second = RuntimeLock(stateDirectory: dir)

        XCTAssertTrue(first.acquire(holder: "PRBar.app"))
        XCTAssertFalse(second.acquire(holder: "prbar-review watch"))
        XCTAssertEqual(second.currentHolder()?.hasSuffix("PRBar.app"), true)

        first.release()
        XCTAssertTrue(second.acquire(holder: "prbar-review watch"))
    }

    /// The runtime only starts reviews when it owns automation; polling
    /// and readiness keep working either way.
    @MainActor
    func testRuntimeWithoutAutomationDoesNotEnqueue() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prbar-rt-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let runtime = RuntimeFixtures.make(dir, ownsAutomation: false)
        runtime.poller.onPollSuccess?([RuntimeFixtures.requestedPR()])
        XCTAssertNil(runtime.queue.reviews["PR_1"])

        runtime.ownsAutomation = true
        runtime.poller.onPollSuccess?([RuntimeFixtures.requestedPR()])
        XCTAssertNotNil(runtime.queue.reviews["PR_1"])
    }
}
