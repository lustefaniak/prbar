import XCTest
@testable import PRBar

@MainActor
final class ReviewLogStoreTests: XCTestCase {

    private func makePR(_ id: String = "PR_TEST", number: Int = 42) -> InboxPR {
        InboxPR(
            nodeId: id, owner: "acme", repo: "infra", number: number,
            title: "Test PR \(number)", body: "", url: URL(string: "https://example.com")!,
            author: "alice", headRef: "feat", baseRef: "main",
            headSha: "deadbeef", isDraft: false,
            role: .reviewRequested,
            mergeable: "MERGEABLE", mergeStateStatus: "CLEAN", reviewDecision: nil,
            checkRollupState: "SUCCESS",
            totalAdditions: 10, totalDeletions: 2, changedFiles: 1,
            hasAutoMerge: false, autoMergeEnabledBy: nil, allCheckSummaries: [],
            allowedMergeMethods: [.squash], autoMergeAllowed: false,
            deleteBranchOnMerge: false
        )
    }

    private func makeAggregated(
        verdict: ReviewVerdict = .approve,
        cost: Double = 0.10
    ) -> AggregatedReview {
        AggregatedReview(
            verdict: verdict,
            confidence: 0.9,
            summaryMarkdown: "ok",
            annotations: [],
            costUsd: cost,
            toolCallCount: 0,
            toolNamesUsed: [],
            perSubreview: [],
            isSubscriptionAuth: false
        )
    }

    func testRecordCompletedRoundTripsAggregated() {
        let store = ReviewLogStore(container: PRBarModelContainer.inMemory())
        let pr = makePR()
        let agg = makeAggregated(verdict: .comment, cost: 0.07)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        store.recordCompleted(
            pr: pr, headSha: "deadbeef", providerId: .claude,
            triggeredAt: t0, completedAt: t0.addingTimeInterval(5),
            review: agg
        )
        let rows = store.fetchAll()
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        XCTAssertEqual(row.status, .completed)
        XCTAssertEqual(row.verdict, .comment)
        XCTAssertEqual(row.costUsd ?? 0, 0.07, accuracy: 1e-9)
        XCTAssertEqual(row.providerId, .claude)
        XCTAssertEqual(row.prNumber, 42)
        let decoded = row.decodeAggregated()
        XCTAssertEqual(decoded?.summaryMarkdown, "ok")
    }

    func testRecordFailedKeepsErrorAndOptionalCost() {
        let store = ReviewLogStore(container: PRBarModelContainer.inMemory())
        store.recordFailed(
            pr: makePR(), headSha: "deadbeef", providerId: .codex,
            triggeredAt: Date(),
            errorMessage: "Daily $5.00 cap reached.", costUsd: 0
        )
        store.recordFailed(
            pr: makePR("PR_2", number: 2), headSha: "deadbeef", providerId: .claude,
            triggeredAt: Date(),
            errorMessage: "Connection reset", costUsd: nil
        )
        let rows = store.fetchAll()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first(where: { $0.providerId == .codex })?.errorMessage,
                       "Daily $5.00 cap reached.")
        XCTAssertNil(rows.first(where: { $0.providerId == .claude })?.costUsd,
                     "nil cost (mid-stream kill / codex) round-trips as nil, not 0")
    }

    func testSpendSinceWindowSumsCostUsd() {
        let store = ReviewLogStore(container: PRBarModelContainer.inMemory())
        let pr = makePR()
        let now = Date()
        let yesterday = now.addingTimeInterval(-86_400 - 60)
        store.recordCompleted(
            pr: pr, headSha: "h1", providerId: .claude,
            triggeredAt: yesterday, completedAt: yesterday,
            review: makeAggregated(cost: 0.50)
        )
        store.recordCompleted(
            pr: pr, headSha: "h2", providerId: .claude,
            triggeredAt: now, completedAt: now,
            review: makeAggregated(cost: 0.20)
        )
        store.recordCompleted(
            pr: pr, headSha: "h3", providerId: .claude,
            triggeredAt: now.addingTimeInterval(-30), completedAt: now,
            review: makeAggregated(cost: 0.05)
        )
        let dayAgo = now.addingTimeInterval(-86_400)
        XCTAssertEqual(store.spend(since: dayAgo), 0.25, accuracy: 1e-9,
                       "rows older than the cutoff are excluded")
    }

    func testSpendIgnoresNilCosts() {
        let store = ReviewLogStore(container: PRBarModelContainer.inMemory())
        store.recordCompleted(
            pr: makePR(), headSha: "h", providerId: .claude,
            triggeredAt: Date(), review: makeAggregated(cost: 0.10)
        )
        store.recordFailed(
            pr: makePR("PR_2", number: 2), headSha: "h", providerId: .claude,
            triggeredAt: Date(),
            errorMessage: "killed mid-stream", costUsd: nil
        )
        XCTAssertEqual(store.spend(since: .distantPast), 0.10, accuracy: 1e-9)
    }

    func testStartOfDayMatchesLocalCalendar() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let noon = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13 UTC
        let start = ReviewLogStore.startOfDay(noon, calendar: cal)
        XCTAssertLessThanOrEqual(start, noon)
        let comps = cal.dateComponents([.hour, .minute, .second], from: start)
        XCTAssertEqual(comps.hour, 0)
        XCTAssertEqual(comps.minute, 0)
        XCTAssertEqual(comps.second, 0)
    }

    func testClearAllWipesEntries() {
        let store = ReviewLogStore(container: PRBarModelContainer.inMemory())
        store.recordCompleted(
            pr: makePR(), headSha: "h", providerId: .claude,
            triggeredAt: Date(), review: makeAggregated(cost: 0.10)
        )
        XCTAssertEqual(store.fetchAll().count, 1)
        store.clearAll()
        XCTAssertEqual(store.fetchAll().count, 0)
    }
}
