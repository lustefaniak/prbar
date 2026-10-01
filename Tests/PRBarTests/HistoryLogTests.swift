import XCTest
import SwiftData
@testable import PRBar

final class HistoryLogTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prbar-history-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func action(_ date: Date, kind: ActionLogKind = .merge) -> ActionRecord {
        ActionRecord(timestamp: date, kind: kind, outcome: .success, prNodeId: "PR_1",
                     owner: "o", repo: "r", prNumber: 1, prTitle: "t")
    }

    private func date(_ text: String) -> Date { HistoryDates.parse(text)! }

    func testRecordsSplitIntoMonthFilesAndReadBack() throws {
        let log = ActionHistory.actions(in: try tempDir())
        try log.append(action(date("2026-08-31T23:59:59.000Z")))
        try log.appendAll([action(date("2026-09-01T00:00:00.000Z")), action(date("2026-10-01T10:00:00.500Z"))])

        XCTAssertEqual(log.monthKeys(), ["2026-08", "2026-09", "2026-10"])
        let all = log.readAll()
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.last?.timestamp, date("2026-10-01T10:00:00.500Z"), "milliseconds survive")
        XCTAssertEqual(log.read(since: date("2026-09-15T00:00:00.000Z")).count, 2, "whole months only")
    }

    func testABadLineDoesNotHideTheRest() throws {
        let dir = try tempDir()
        let log = ActionHistory.actions(in: dir)
        try log.append(action(date("2026-10-01T10:00:00.000Z")))
        let file = dir.appendingPathComponent("actions/2026-10.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data("{not json\n".utf8))
        handle.closeFile()
        try log.append(action(date("2026-10-02T10:00:00.000Z")))
        XCTAssertEqual(log.readAll().count, 2)
    }

    func testUnknownKindReadsAsOther() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("actions/2026-10.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"kind":"from_the_future","outcome":"success","owner":"o","repo":"r","prNumber":1,"timestamp":"2026-10-01T10:00:00.000Z"}"#.utf8 + [0x0A]).write(to: file)
        XCTAssertEqual(ActionHistory.actions(in: dir).readAll().first?.kind, .other)
    }

    func testPruneDropsWholeMonthsAndTheirReviewFiles() throws {
        let dir = try tempDir()
        let reviews = ReviewHistory(in: dir)
        let old = ReviewRecord(prNodeId: "PR_1", owner: "o", repo: "r", prNumber: 1, prTitle: "t",
                               headSha: "a", providerId: .claude, triggeredAt: date("2026-06-10T00:00:00.000Z"),
                               completedAt: date("2026-06-10T00:01:00.000Z"), status: .completed)
        var recent = old
        recent.id = UUID()
        recent.triggeredAt = date("2026-10-01T00:00:00.000Z")
        let review = AggregatedReview(verdict: .approve, confidence: 0.9, summaryMarkdown: "s", annotations: [],
                                      costUsd: 0, toolCallCount: 0, toolNamesUsed: [], perSubreview: [],
                                      isSubscriptionAuth: false)
        try reviews.append(old, review: review)
        try reviews.append(recent, review: review)

        reviews.prune(before: date("2026-08-01T00:00:00.000Z"))

        XCTAssertEqual(reviews.readAll().map(\.id), [recent.id])
        XCTAssertNil(reviews.review(id: old.id))
        XCTAssertNotNil(reviews.review(id: recent.id))
    }

    @MainActor
    func testLegacySwiftDataHistoryMigratesOnce() throws {
        let dir = try tempDir()
        let container = PRBarModelContainer.inMemory()
        let context = ModelContext(container)
        context.insert(ActionLogEntry(kind: .autoShare, outcome: .failure, errorMessage: "422",
                                      prNodeId: "PR_1", owner: "o", repo: "r", prNumber: 7, prTitle: "Fix",
                                      headSha: "abc", detail: "body", costUsd: 0.2))
        let review = AggregatedReview(verdict: .comment, confidence: 0.8, summaryMarkdown: "legacy", annotations: [],
                                      costUsd: 0.4, toolCallCount: 1, toolNamesUsed: ["Read"], perSubreview: [],
                                      isSubscriptionAuth: false)
        let completed = ReviewLogEntry(prNodeId: "PR_1", owner: "o", repo: "r", prNumber: 7, prTitle: "Fix",
                                       headSha: "abc", providerId: .codex, triggeredAt: Date(), completedAt: Date(),
                                       status: .completed, verdict: .comment, costUsd: 0.4,
                                       payload: try ReviewHistory.encodeReview(review))
        let failed = ReviewLogEntry(prNodeId: "PR_2", owner: "o", repo: "r", prNumber: 8, prTitle: "Other",
                                    headSha: "def", providerId: .claude, triggeredAt: Date(), completedAt: Date(),
                                    status: .failed, errorMessage: "timeout")
        context.insert(completed)
        context.insert(failed)
        try context.save()

        LegacyHistoryMigration.migrateIfNeeded(historyDirectory: dir, container: container)

        let actions = ActionLogStore(history: .actions(in: dir))
        XCTAssertEqual(actions.entries.count, 1)
        XCTAssertEqual(actions.entries.first?.kind, .autoShare)
        XCTAssertEqual(actions.entries.first?.errorMessage, "422")
        XCTAssertEqual(actions.entries.first?.costUsd, 0.2)

        let reviews = ReviewLogStore(history: ReviewHistory(in: dir))
        XCTAssertEqual(reviews.entries.count, 2)
        let migrated = try XCTUnwrap(reviews.entries.first { $0.id == completed.id })
        XCTAssertEqual(migrated.providerId, .codex)
        XCTAssertEqual(reviews.review(for: migrated.id)?.summaryMarkdown, "legacy")
        XCTAssertEqual(reviews.entries.first { $0.id == failed.id }?.errorMessage, "timeout")
        XCTAssertEqual(reviews.todaysSpend(), 0.4, accuracy: 1e-9)

        // Cleared history must stay cleared: the marker, not emptiness,
        // decides whether to migrate.
        reviews.clearAll()
        actions.clearAll()
        LegacyHistoryMigration.migrateIfNeeded(historyDirectory: dir, container: container)
        XCTAssertTrue(ReviewLogStore(history: ReviewHistory(in: dir)).entries.isEmpty)
        XCTAssertTrue(ActionLogStore(history: .actions(in: dir)).entries.isEmpty)
    }
}
