import XCTest
@testable import PRBar

final class StoreRetentionTests: XCTestCase {
    func testSweepDeletesEntriesPastTheirLimitAndKeepsFresherOnes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prbar-cache-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        func ago(_ days: Double) -> Date { now.addingTimeInterval(-StoreRetention.days(days)) }

        let diffs = FileCache(directory: dir.appendingPathComponent("diffs"))
        let logs = FileCache(directory: dir.appendingPathComponent("ci-logs"))
        for (cache, key, date) in [(diffs, "fresh", ago(1)), (diffs, "stale", ago(30)),
                                   (logs, "fresh", ago(1)), (logs, "stale", ago(60))] {
            cache.write(key, Data("x".utf8))
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: cache.url(for: key).path)
        }

        StoreRetention.sweepCaches(in: dir, now: now)

        XCTAssertNotNil(diffs.read("fresh"))
        XCTAssertNil(diffs.read("stale"))
        XCTAssertNotNil(logs.read("fresh"))
        XCTAssertNil(logs.read("stale"))
    }

    func testCacheKeysCannotEscapeTheDirectory() {
        let cache = FileCache(directory: URL(fileURLWithPath: "/tmp/prbar-cache"))
        XCTAssertEqual(cache.url(for: "../../etc/passwd").deletingLastPathComponent().path, "/tmp/prbar-cache")
        XCTAssertFalse(cache.url(for: ".hidden").lastPathComponent.hasPrefix("."))
        XCTAssertEqual(cache.url(for: "PR_kwDO@abc123#42").lastPathComponent, "PR_kwDO@abc123_42")
    }
}
