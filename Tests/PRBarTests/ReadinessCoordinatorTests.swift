import XCTest
@testable import PRBar

@MainActor
final class ReadinessCoordinatorTests: XCTestCase {
    func testEachReadyFiresImmediatelyWhenPolicySaysSo() async throws {
        let recorder = RecordingDeliverer()
        let notifier = Notifier(deliverer: recorder)
        notifier.debounceWindow = .milliseconds(40)
        let coord = ReadinessCoordinator(notifier: notifier, store: InMemoryNotifiedSHAStore())

        var cfg = RepoConfig.default
        cfg.notifyPolicy = .eachReady
        // AI off so the PR is "ready for human" the instant it's tracked.
        cfg.aiReviewEnabled = false
        let pr = makePR(nodeId: "P1")

        coord.track(prs: [pr]) { _, _ in cfg }

        try await Task.sleep(for: .milliseconds(120))
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 1, ".eachReady with AI off should fire on first track()")
        XCTAssertEqual(calls.first?.map(\.prNodeId), ["P1"])
    }

    func testBatchSettledHoldsUntilWorkerSettles() async throws {
        let recorder = RecordingDeliverer()
        let notifier = Notifier(deliverer: recorder)
        notifier.debounceWindow = .milliseconds(40)
        let coord = ReadinessCoordinator(notifier: notifier, store: InMemoryNotifiedSHAStore())

        var cfg = RepoConfig.default
        cfg.notifyPolicy = .batchSettled
        cfg.aiReviewEnabled = true
        let p1 = makePR(nodeId: "P1")
        let p2 = makePR(nodeId: "P2")

        coord.track(prs: [p1, p2]) { _, _ in cfg }

        // First triage finishes but worker is not yet settled.
        coord.noteReviewSettled(prNodeId: "P1", isWorkerSettled: false)
        try await Task.sleep(for: .milliseconds(80))
        let firstCalls = await recorder.calls
        XCTAssertTrue(firstCalls.isEmpty, "no notification while worker still has reviews in flight")

        // Second triage finishes, worker idles → flush as one batch.
        coord.noteReviewSettled(prNodeId: "P2", isWorkerSettled: true)
        try await Task.sleep(for: .milliseconds(80))
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 1, "settled flush should produce one delivery")
        XCTAssertEqual(Set(calls.first?.map(\.prNodeId) ?? []), ["P1", "P2"])
    }

    func testAIDisabledRideAlongInBatch() async throws {
        let recorder = RecordingDeliverer()
        let notifier = Notifier(deliverer: recorder)
        notifier.debounceWindow = .milliseconds(40)
        let coord = ReadinessCoordinator(notifier: notifier, store: InMemoryNotifiedSHAStore())

        var aiOn = RepoConfig.default
        aiOn.notifyPolicy = .batchSettled
        aiOn.aiReviewEnabled = true
        var aiOff = RepoConfig.default
        aiOff.notifyPolicy = .batchSettled
        aiOff.aiReviewEnabled = false

        let withAI = makePR(nodeId: "WAI", repo: "ai")
        let noAI   = makePR(nodeId: "NOAI", repo: "no-ai")

        coord.track(prs: [withAI, noAI]) { _, repo in
            repo == "ai" ? aiOn : aiOff
        }

        // No-AI PR doesn't trigger anything yet — we're still in batch mode
        // and the AI-on PR is mid-triage.
        try await Task.sleep(for: .milliseconds(80))
        let preFlush = await recorder.calls
        XCTAssertTrue(preFlush.isEmpty)

        coord.noteReviewSettled(prNodeId: "WAI", isWorkerSettled: true)
        try await Task.sleep(for: .milliseconds(80))
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(Set(calls.first?.map(\.prNodeId) ?? []), ["WAI", "NOAI"])
    }

    func testNotificationDoesNotRepeatOnSubsequentPolls() async throws {
        let recorder = RecordingDeliverer()
        let notifier = Notifier(deliverer: recorder)
        notifier.debounceWindow = .milliseconds(40)
        let coord = ReadinessCoordinator(notifier: notifier, store: InMemoryNotifiedSHAStore())

        var cfg = RepoConfig.default
        cfg.notifyPolicy = .eachReady
        cfg.aiReviewEnabled = false
        let pr = makePR(nodeId: "P1")

        coord.track(prs: [pr]) { _, _ in cfg }
        coord.track(prs: [pr]) { _, _ in cfg }     // same PR, second poll
        try await Task.sleep(for: .milliseconds(120))

        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 1, "should only fire once per PR readiness transition")
    }

    func testPersistentDedupAcrossRestartSameSHA() async throws {
        // First "session" — fires once, persists notifiedSHA.
        let store = InMemoryNotifiedSHAStore()
        let recorder1 = RecordingDeliverer()
        let n1 = Notifier(deliverer: recorder1)
        n1.debounceWindow = .milliseconds(40)
        let coord1 = ReadinessCoordinator(notifier: n1, store: store)
        var cfg = RepoConfig.default
        cfg.notifyPolicy = .eachReady
        cfg.aiReviewEnabled = false
        let pr = makePR(nodeId: "P1")

        coord1.track(prs: [pr]) { _, _ in cfg }
        try await Task.sleep(for: .milliseconds(120))
        let firstCalls = await recorder1.calls
        XCTAssertEqual(firstCalls.count, 1)

        // Second "session" — same store, same PR/SHA. Must NOT re-fire.
        let recorder2 = RecordingDeliverer()
        let n2 = Notifier(deliverer: recorder2)
        n2.debounceWindow = .milliseconds(40)
        let coord2 = ReadinessCoordinator(notifier: n2, store: store)

        coord2.track(prs: [pr]) { _, _ in cfg }
        try await Task.sleep(for: .milliseconds(120))
        let secondCalls = await recorder2.calls
        XCTAssertEqual(secondCalls.count, 0,
                       "same PR + same SHA across restarts must not re-notify")
    }

    func testNewCommitReArmsAfterRestart() async throws {
        // First "session" — fires for SHA "abc".
        let store = InMemoryNotifiedSHAStore()
        let recorder1 = RecordingDeliverer()
        let n1 = Notifier(deliverer: recorder1)
        n1.debounceWindow = .milliseconds(40)
        let coord1 = ReadinessCoordinator(notifier: n1, store: store)
        var cfg = RepoConfig.default
        cfg.notifyPolicy = .eachReady
        cfg.aiReviewEnabled = false

        coord1.track(prs: [makePR(nodeId: "P1", headSha: "abc")]) { _, _ in cfg }
        try await Task.sleep(for: .milliseconds(120))
        let firstCalls = await recorder1.calls
        XCTAssertEqual(firstCalls.count, 1)

        // Second session — PR has new commits (different SHA). Must fire again.
        let recorder2 = RecordingDeliverer()
        let n2 = Notifier(deliverer: recorder2)
        n2.debounceWindow = .milliseconds(40)
        let coord2 = ReadinessCoordinator(notifier: n2, store: store)

        coord2.track(prs: [makePR(nodeId: "P1", headSha: "def")]) { _, _ in cfg }
        try await Task.sleep(for: .milliseconds(120))
        let secondCalls = await recorder2.calls
        XCTAssertEqual(secondCalls.count, 1,
                       "new head SHA must re-arm the notification")
    }

    // MARK: helpers

    private func makePR(nodeId: String, repo: String = "r", headSha: String = "abc") -> InboxPR {
        InboxPR(
            nodeId: nodeId,
            owner: "o",
            repo: repo,
            number: 1,
            title: "t",
            body: "",
            url: URL(string: "https://github.com/o/\(repo)/pull/1")!,
            author: "alice",
            headRef: "h",
            baseRef: "main",
            headSha: headSha,
            isDraft: false,
            role: .reviewRequested,
            mergeable: "MERGEABLE",
            mergeStateStatus: "BLOCKED",
            reviewDecision: "REVIEW_REQUIRED",
            checkRollupState: "PENDING",
            totalAdditions: 1,
            totalDeletions: 0,
            changedFiles: 1,
            hasAutoMerge: false,
            autoMergeEnabledBy: nil,
            allCheckSummaries: [],
            allowedMergeMethods: [.squash],
            autoMergeAllowed: true,
            deleteBranchOnMerge: true
        )
    }
}

private actor RecordingDeliverer: NotificationDeliverer {
    private(set) var calls: [[NotificationEvent]] = []
    func requestAuthorization() async {}
    func deliver(_ events: [NotificationEvent]) async {
        calls.append(events)
    }
}

private final class InMemoryNotifiedSHAStore: NotifiedSHAStore, @unchecked Sendable {
    private var map: [String: String] = [:]
    func load() -> [String: String] { map }
    func save(_ map: [String: String]) { self.map = map }
}
