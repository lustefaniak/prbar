import XCTest
@testable import PRBar

@MainActor
final class PRPollerTests: XCTestCase {
    func testPollNowFetchesAndStoresPRs() async throws {
        let fixture = makePR(nodeId: "PR_a", number: 1, title: "first")
        let poller = PRPoller(fetcher: { [fixture] })

        XCTAssertTrue(poller.prs.isEmpty)
        XCTAssertNil(poller.lastFetchedAt)

        poller.pollNow()
        try await waitUntil { poller.prs.count == 1 }

        XCTAssertEqual(poller.prs.first?.title, "first")
        XCTAssertNotNil(poller.lastFetchedAt)
        XCTAssertNil(poller.lastError)
    }

    func testFetchErrorSurfacedViaLastError() async throws {
        struct StubError: Error, LocalizedError {
            var errorDescription: String? { "boom" }
        }
        let poller = PRPoller(fetcher: { throw StubError() })

        poller.pollNow()
        try await waitUntil { poller.lastError != nil }

        XCTAssertEqual(poller.lastError, "boom")
        XCTAssertTrue(poller.prs.isEmpty)
    }

    func testDeltaAddedAndRemoved() {
        let a = makePR(nodeId: "A", number: 1, title: "a")
        let b = makePR(nodeId: "B", number: 2, title: "b")
        let c = makePR(nodeId: "C", number: 3, title: "c")

        let delta = PRPoller.computeDelta(old: [a, b], new: [b, c])
        XCTAssertEqual(delta.added.map(\.nodeId), ["C"])
        XCTAssertEqual(delta.removed.map(\.nodeId), ["A"])
        XCTAssertTrue(delta.changed.isEmpty)
    }

    func testDeltaChangedDetectsTitleEdit() {
        let aBefore = makePR(nodeId: "A", number: 1, title: "old title")
        let aAfter  = makePR(nodeId: "A", number: 1, title: "new title")

        let delta = PRPoller.computeDelta(old: [aBefore], new: [aAfter])
        XCTAssertTrue(delta.added.isEmpty)
        XCTAssertTrue(delta.removed.isEmpty)
        XCTAssertEqual(delta.changed.map(\.title), ["new title"])
    }

    func testDeltaUnchangedIsEmpty() {
        let a = makePR(nodeId: "A", number: 1, title: "a")
        let delta = PRPoller.computeDelta(old: [a], new: [a])
        XCTAssertTrue(delta.isEmpty)
    }

    func testRefreshPRReplacesEntryInPlace() async throws {
        let original = makePR(nodeId: "PR_a", number: 1, title: "before")
        let updated  = makePR(nodeId: "PR_a", number: 1, title: "after")

        let poller = PRPoller(
            fetcher: { [original] },
            prRefresher: { _, _, _ in updated }
        )
        poller.pollNow()
        try await waitUntil { poller.prs.first?.title == "before" }

        poller.refreshPR(original)
        try await waitUntil { poller.prs.first?.title == "after" }

        XCTAssertEqual(poller.prs.count, 1)
        XCTAssertTrue(poller.refreshingPRs.isEmpty, "should clear after refresh")
    }

    func testRefreshPRSurfacesErrorWithoutRemovingEntry() async throws {
        struct StubError: Error, LocalizedError {
            var errorDescription: String? { "rate limited" }
        }
        let pr = makePR(nodeId: "PR_a", number: 1, title: "stays")
        let poller = PRPoller(
            fetcher: { [pr] },
            prRefresher: { _, _, _ in throw StubError() }
        )
        poller.pollNow()
        try await waitUntil { poller.prs.count == 1 }

        poller.refreshPR(pr)
        try await waitUntil { poller.lastError != nil }

        XCTAssertEqual(poller.prs.first?.title, "stays")
        XCTAssertEqual(poller.lastError, "rate limited")
    }

    func testMergePRCallsMergerThenRefreshes() async throws {
        let pr = makePR(nodeId: "PR_a", number: 7, title: "ready")
        let updated = makePR(nodeId: "PR_a", number: 7, title: "merged")

        let mergeRecorder = AsyncRecorder()

        let poller = PRPoller(
            fetcher: { [pr] },
            prRefresher: { _, _, _ in updated },
            prMerger: { owner, repo, number, method in
                await mergeRecorder.record("\(owner)/\(repo)#\(number) [\(method.rawValue)]")
            }
        )
        poller.pollNow()
        try await waitUntil { poller.prs.first?.title == "ready" }

        poller.mergePR(pr, method: .squash)
        try await waitUntil { poller.prs.first?.title == "merged" }

        let calls = await mergeRecorder.calls
        XCTAssertEqual(calls, ["o/r#7 [squash]"])
        XCTAssertTrue(poller.mergingPRs.isEmpty, "should clear after merge")
    }

    func testMergePRSurfacesError() async throws {
        struct StubError: Error, LocalizedError {
            var errorDescription: String? { "PR not in mergeable state" }
        }
        let pr = makePR(nodeId: "PR_a", number: 7, title: "blocked")
        let poller = PRPoller(
            fetcher: { [pr] },
            prMerger: { _, _, _, _ in throw StubError() }
        )
        poller.pollNow()
        try await waitUntil { poller.prs.count == 1 }

        poller.mergePR(pr, method: .squash)
        try await waitUntil { poller.lastError != nil }

        XCTAssertEqual(poller.lastError, "PR not in mergeable state")
        XCTAssertEqual(poller.prs.first?.title, "blocked")
    }

    func testRefreshPRWithoutRefresherFallsBackToPollNow() async throws {
        let counter = AsyncCounter()
        let pr = makePR(nodeId: "PR_a", number: 1, title: "x")
        let poller = PRPoller(fetcher: {
            await counter.increment()
            return [pr]
        })
        poller.pollNow()
        try await waitUntil { poller.prs.count == 1 }
        let initialCount = await counter.value

        // Without prRefresher, refreshPR falls back to pollNow → another full fetch.
        poller.refreshPR(pr)

        let deadline = Date().addingTimeInterval(2)
        while await counter.value <= initialCount {
            if Date() > deadline {
                XCTFail("refreshPR did not trigger fetcher")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testStartIsIdempotent() async throws {
        let counter = AsyncCounter()
        let poller = PRPoller(fetcher: {
            await counter.increment()
            return []
        })
        poller.pollInterval = 0.05  // 50ms — keep test fast

        poller.start()
        poller.start()  // second call is no-op
        poller.start()  // third call is no-op

        try await Task.sleep(for: .milliseconds(180))
        poller.stop()

        // We expect ~3 fetches in 180ms at 50ms cadence; tolerate range to
        // avoid flakes on slow CI. Exactly one polling task should be active.
        let count = await counter.value
        XCTAssertGreaterThanOrEqual(count, 2)
        XCTAssertLessThan(count, 6, "more than one polling loop running — start() not idempotent")
    }

    // MARK: - helpers

    private func makePR(nodeId: String, number: Int, title: String) -> InboxPR {
        InboxPR(
            nodeId: nodeId,
            owner: "o",
            repo: "r",
            number: number,
            title: title,
            body: "",
            url: URL(string: "https://github.com/o/r/pull/\(number)")!,
            author: "alice",
            headRef: "h",
            baseRef: "main",
            isDraft: false,
            role: .reviewRequested,
            mergeable: "MERGEABLE",
            mergeStateStatus: "CLEAN",
            reviewDecision: nil,
            checkRollupState: "SUCCESS",
            totalAdditions: 1,
            totalDeletions: 0,
            changedFiles: 1,
            hasAutoMerge: false,
            autoMergeEnabledBy: nil,
            allCheckSummaries: []
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeout.components.seconds))
        while !condition() {
            if Date() > deadline {
                XCTFail("waitUntil timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private actor AsyncCounter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}

private actor AsyncRecorder {
    private(set) var calls: [String] = []
    func record(_ s: String) { calls.append(s) }
}
