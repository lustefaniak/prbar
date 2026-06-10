import XCTest
@testable import PRBar

@MainActor
final class ActionQueueTests: XCTestCase {

    // MARK: - success paths

    func testReviewActionRunsExecutorThenClearsAndCompletes() async throws {
        let pr = makePR(nodeId: "PR_a", number: 7, title: "review me")
        let reviewRec = AsyncRecorder()
        let completed = AsyncRecorder()

        let q = ActionQueue()
        q.reviewExecutor = { pr, kind, body, comments in
            await reviewRec.record("\(pr.owner)/\(pr.repo)#\(pr.number) \(kind.rawValue) body=\(body) inline=\(comments.count)")
        }
        q.onActionCompleted = { pr in
            Task { await completed.record(pr.nodeId) }
        }

        q.enqueue(pr, kind: .review(kind: .approve, body: "lgtm", comments: []))
        try await waitUntil { q.state(for: "PR_a") == nil }

        let calls = await reviewRec.calls
        XCTAssertEqual(calls, ["o/r#7 approve body=lgtm inline=0"])
        try await waitUntil { await completed.calls == ["PR_a"] }
    }

    func testMergeActionRunsExecutorThenClears() async throws {
        let pr = makePR(nodeId: "PR_a", number: 7, title: "ready")
        let mergeRec = AsyncRecorder()

        let q = ActionQueue()
        q.mergeExecutor = { pr, method in
            await mergeRec.record("\(pr.owner)/\(pr.repo)#\(pr.number) [\(method.rawValue)]")
        }

        q.enqueue(pr, kind: .merge(method: .squash))
        try await waitUntil { q.state(for: "PR_a") == nil }

        let calls = await mergeRec.calls
        XCTAssertEqual(calls, ["o/r#7 [squash]"])
    }

    func testEnableAutoMergeRunsAutoMergeExecutor() async throws {
        let pr = makePR(nodeId: "PR_a", number: 7, title: "queued")
        let autoRec = AsyncRecorder()
        let mergeRec = AsyncRecorder()

        let q = ActionQueue()
        q.mergeExecutor = { _, method in await mergeRec.record(method.rawValue) }
        q.autoMergeExecutor = { pr, method in
            await autoRec.record("\(pr.owner)/\(pr.repo)#\(pr.number) [\(method.rawValue)]")
        }

        q.enqueue(pr, kind: .enableAutoMerge(method: .squash))
        try await waitUntil { q.state(for: "PR_a") == nil }

        let auto = await autoRec.calls
        let merge = await mergeRec.calls
        XCTAssertEqual(auto, ["o/r#7 [squash]"])
        XCTAssertTrue(merge.isEmpty, "enable-auto-merge must not run the immediate-merge executor")
    }

    func testDisableAutoMergeRunsDisableExecutor() async throws {
        let pr = makePR(nodeId: "PR_a", number: 7, title: "cancel queued")
        let rec = AsyncRecorder()

        let q = ActionQueue()
        q.disableAutoMergeExecutor = { pr in await rec.record(pr.nodeId) }

        q.enqueue(pr, kind: .disableAutoMerge)
        try await waitUntil { q.state(for: "PR_a") == nil }

        let calls = await rec.calls
        XCTAssertEqual(calls, ["PR_a"])
    }

    func testEnableAutoMergeWithDisallowedMethodFailsImmediately() async throws {
        let pr = makePR(
            nodeId: "PR_a", number: 7, title: "linear-only",
            allowedMergeMethods: [.squash, .rebase]
        )
        let rec = AsyncRecorder()
        let q = ActionQueue()
        q.autoMergeExecutor = { _, method in await rec.record(method.rawValue) }

        q.enqueue(pr, kind: .enableAutoMerge(method: .merge))   // disallowed

        guard case .failed(let msg) = q.state(for: "PR_a") else {
            return XCTFail("expected immediate failed state")
        }
        XCTAssertTrue(msg.contains("disabled"))
        try await Task.sleep(for: .milliseconds(50))
        let calls = await rec.calls
        XCTAssertTrue(calls.isEmpty, "auto-merge executor must not run for a disallowed method")
    }

    func testSuccessFlashIsSetThenClears() async throws {
        let pr = makePR(nodeId: "PR_a", number: 7, title: "ready")
        let q = ActionQueue()
        q.successDisplayDuration = .milliseconds(60)
        q.mergeExecutor = { _, _ in }

        q.enqueue(pr, kind: .merge(method: .squash))
        // Flash appears once the action settles.
        try await waitUntil { q.recentSuccess["PR_a"] == .merge(method: .squash) }
        // And auto-clears after the display window.
        try await waitUntil { q.recentSuccess["PR_a"] == nil }
    }

    // MARK: - dedup / serialization

    func testSecondEnqueueWhileBusyIsNoOp() async throws {
        let pr = makePR(nodeId: "PR_a", number: 7, title: "ready")
        let mergeRec = AsyncRecorder()

        let q = ActionQueue()
        q.mergeExecutor = { pr, method in
            await mergeRec.record("\(method.rawValue)")
        }

        // The second enqueue runs synchronously before the first run Task
        // gets a turn, so it sees a busy (.queued) slot and is dropped.
        q.enqueue(pr, kind: .merge(method: .squash))
        q.enqueue(pr, kind: .merge(method: .rebase))
        XCTAssertTrue(q.isBusy("PR_a"))

        try await waitUntil { q.state(for: "PR_a") == nil }
        let calls = await mergeRec.calls
        XCTAssertEqual(calls, ["squash"], "second enqueue while busy must be dropped")
    }

    func testDifferentPRsBothExecute() async throws {
        let a = makePR(nodeId: "PR_a", number: 1, title: "a")
        let b = makePR(nodeId: "PR_b", number: 2, title: "b")
        let rec = AsyncRecorder()

        let q = ActionQueue()
        q.mergeExecutor = { pr, _ in await rec.record(pr.nodeId) }

        q.enqueue(a, kind: .merge(method: .squash))
        q.enqueue(b, kind: .merge(method: .squash))

        try await waitUntil { q.state(for: "PR_a") == nil && q.state(for: "PR_b") == nil }
        let calls = await rec.calls.sorted()
        XCTAssertEqual(calls, ["PR_a", "PR_b"])
    }

    // MARK: - failure + retry

    func testFailureRetainsFailedStateThenRetrySucceeds() async throws {
        struct StubError: Error, LocalizedError {
            var errorDescription: String? { "gh exploded" }
        }
        let pr = makePR(nodeId: "PR_a", number: 7, title: "flaky")
        let attempts = AsyncCounter()

        let q = ActionQueue()
        q.mergeExecutor = { _, _ in
            let n = await attempts.incrementAndGet()
            if n == 1 { throw StubError() }
        }

        q.enqueue(pr, kind: .merge(method: .squash))
        try await waitUntil { q.state(for: "PR_a") == .failed("gh exploded") }

        // The captured action survives — retry re-runs it verbatim.
        q.retry("PR_a")
        try await waitUntil { q.state(for: "PR_a") == nil }
        let total = await attempts.value
        XCTAssertEqual(total, 2, "retry should re-run the executor")
    }

    func testDismissFailureClearsEntry() async throws {
        struct StubError: Error, LocalizedError {
            var errorDescription: String? { "nope" }
        }
        let pr = makePR(nodeId: "PR_a", number: 7, title: "x")
        let q = ActionQueue()
        q.mergeExecutor = { _, _ in throw StubError() }

        q.enqueue(pr, kind: .merge(method: .squash))
        try await waitUntil { q.state(for: "PR_a") == .failed("nope") }

        q.dismissFailure("PR_a")
        XCTAssertNil(q.state(for: "PR_a"))
    }

    func testDisallowedMergeMethodFailsImmediatelyWithoutRunning() async throws {
        // Repo disallows merge commits (linear history).
        let pr = makePR(
            nodeId: "PR_a", number: 7, title: "linear-only",
            allowedMergeMethods: [.squash, .rebase]
        )
        let rec = AsyncRecorder()
        let q = ActionQueue()
        q.mergeExecutor = { _, method in await rec.record(method.rawValue) }

        q.enqueue(pr, kind: .merge(method: .merge))   // disallowed

        guard case .failed(let msg) = q.state(for: "PR_a") else {
            return XCTFail("expected immediate failed state")
        }
        XCTAssertTrue(msg.contains("disabled"), "message should explain the method is disabled")
        // Give any (incorrectly) dispatched run a chance to fire.
        try await Task.sleep(for: .milliseconds(50))
        let calls = await rec.calls
        XCTAssertTrue(calls.isEmpty, "executor must not run for a disallowed method")
    }

    func testReviewErrorSurfacedAsFailedState() async throws {
        struct StubError: Error, LocalizedError {
            var errorDescription: String? { "422 unprocessable" }
        }
        let pr = makePR(nodeId: "PR_a", number: 7, title: "bad")
        let q = ActionQueue()
        q.reviewExecutor = { _, _, _, _ in throw StubError() }

        q.enqueue(pr, kind: .review(kind: .comment, body: "x", comments: []))
        try await waitUntil { q.state(for: "PR_a") == .failed("422 unprocessable") }
    }

    // MARK: - helpers

    private func makePR(
        nodeId: String,
        number: Int,
        title: String,
        allowedMergeMethods: Set<MergeMethod> = [.squash, .rebase]
    ) -> InboxPR {
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
            headSha: "abc123",
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
            allCheckSummaries: [],
            allowedMergeMethods: allowedMergeMethods,
            autoMergeAllowed: true,
            deleteBranchOnMerge: true
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !(await condition()) {
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
    func incrementAndGet() -> Int { value += 1; return value }
}

private actor AsyncRecorder {
    private(set) var calls: [String] = []
    func record(_ s: String) { calls.append(s) }
}
