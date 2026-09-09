import XCTest
import SwiftData
@testable import PRBar

final class StoreRetentionTests: XCTestCase {
    func testSweepDeletesRowsPastTheirLimitAndKeepsFresherOnes() throws {
        let container = PRBarModelContainer.inMemory()
        let context = ModelContext(container)
        let now = Date()
        func ago(_ days: Double) -> Date { now.addingTimeInterval(-StoreRetention.days(days)) }

        context.insert(DiffCacheEntry(cacheKey: "fresh", payload: Data(), savedAt: ago(1)))
        context.insert(DiffCacheEntry(cacheKey: "stale", payload: Data(), savedAt: ago(30)))
        context.insert(FailureLogCacheEntry(cacheKey: "fresh", tail: "", savedAt: ago(1)))
        context.insert(FailureLogCacheEntry(cacheKey: "stale", tail: "", savedAt: ago(60)))
        try context.save()

        StoreRetention.sweep(container, now: now)

        let diffs = try ModelContext(container).fetch(FetchDescriptor<DiffCacheEntry>())
        XCTAssertEqual(diffs.map(\.cacheKey), ["fresh"])
        let logs = try ModelContext(container).fetch(FetchDescriptor<FailureLogCacheEntry>())
        XCTAssertEqual(logs.map(\.cacheKey), ["fresh"])
    }
}
