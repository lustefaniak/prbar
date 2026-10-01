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

@MainActor
final class RuntimeMaintenanceTests: XCTestCase {
    /// Whatever hosts the runtime evicts old history: before this ran in
    /// the runtime, only the app did, so a long-running `serve` kept
    /// everything forever.
    func testMaintenanceEvictsOldHistoryAndCaches() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prbar-maint-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let runtime = RuntimeFixtures.make(dir, ownsAutomation: false)
        let pr = RuntimeFixtures.requestedPR()
        let now = Date()
        runtime.actionLog.record(kind: ActionLogKind.allCases[0], outcome: .success, pr: pr,
                                 timestamp: now.addingTimeInterval(-StoreRetention.actionLog - 86400))
        runtime.actionLog.record(kind: ActionLogKind.allCases[0], outcome: .success, pr: pr, timestamp: now)
        let cache = dir.appendingPathComponent("cache")
        let diffs = FileCache(directory: cache.appendingPathComponent("diffs"))
        diffs.write("old", Data("x".utf8))
        let old = now.addingTimeInterval(-StoreRetention.diffCache - 86400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: diffs.url(for: "old").path)

        await runtime.runMaintenance(cacheDirectory: cache, now: now)
        XCTAssertEqual(runtime.actionLog.entries.count, 1)
        XCTAssertNil(diffs.read("old"))
    }
}

@MainActor
final class LegacyMaterializationTests: XCTestCase {
    /// A server in another process has no legacy fallbacks, so whatever the
    /// app could only read from the old store has to be on disk first.
    func testWritesMissingFilesFromTheFallbacksOnce() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prbar-legacy-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        var env = RuntimeEnvironment(
            configFile: dir.appendingPathComponent("config/prbar.yaml"), lastGoodConfig: nil,
            stateDirectory: dir.appendingPathComponent("state"), cacheDirectory: dir.appendingPathComponent("cache"))
        var legacy = PRBarConfig()
        legacy.defaults.maxCostUsdPerSubreview = 7
        env.legacyConfig = { legacy }
        env.legacyInbox = { [RuntimeFixtures.requestedPR()] }
        env.legacyNotified = { ["PR_1": "abc123"] }

        env.materializeLegacyFiles()
        XCTAssertEqual(try ConfigFile.load(url: env.configFile).config.defaults.maxCostUsdPerSubreview, 7)
        XCTAssertEqual(SnapshotCache(stateDirectory: env.stateDirectory).load().map(\.nodeId), ["PR_1"])
        XCTAssertEqual(FileNotifiedSHAStore(stateDirectory: env.stateDirectory).load(), ["PR_1": "abc123"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.stateDirectory.appendingPathComponent("review-state.json").path),
                       "no fallback, no file")

        env.legacyInbox = { [] }
        env.materializeLegacyFiles()
        XCTAssertEqual(SnapshotCache(stateDirectory: env.stateDirectory).load().count, 1, "an existing file is left alone")
    }
}
