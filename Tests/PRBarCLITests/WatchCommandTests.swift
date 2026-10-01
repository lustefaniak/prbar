import XCTest
@testable import PRBarCore

final class WatchCommandTests: XCTestCase {
    func testOptionsParse() {
        XCTAssertEqual(WatchCommand.Options(args: [])?.configPath, nil)
        XCTAssertEqual(WatchCommand.Options(args: ["--config", "x.yaml"])?.configPath, "x.yaml")
        XCTAssertEqual(WatchCommand.Options(args: ["--daily-cap", "12.5"])?.dailyCapUsd, 12.5)
        XCTAssertEqual(WatchCommand.Options(args: ["--daily-cap", "off"])?.dailyCapUsd, 0)
        XCTAssertNil(WatchCommand.Options(args: ["--daily-cap", "-1"]))
        XCTAssertNil(WatchCommand.Options(args: ["--config"]))
        XCTAssertNil(WatchCommand.Options(args: ["owner/repo#1"]))
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
        let runtime = makeRuntime(dir, ownsAutomation: false)
        runtime.poller.onPollSuccess?([Self.requestedPR()])
        XCTAssertNil(runtime.queue.reviews["PR_1"])

        runtime.ownsAutomation = true
        runtime.poller.onPollSuccess?([Self.requestedPR()])
        XCTAssertNotNil(runtime.queue.reviews["PR_1"])
    }

    @MainActor
    private func makeRuntime(_ dir: URL, ownsAutomation: Bool) -> PRBarRuntime {
        let notifier = Notifier(deliverer: StderrDeliverer())
        let queue = ReviewQueueWorker(diffFetcher: { _, _, _ in "" })
        queue.providerLookup = { _ in NeverProvider() }
        return PRBarRuntime(
            poller: PRPoller(fetcher: { [] }),
            notifier: notifier,
            queue: queue,
            actionQueue: ActionQueue(),
            diffStore: DiffStore(diffFetcher: { _, _, _ in "" }),
            failureLogs: FailureLogStore(logFetcher: { _, _, _ in "" }),
            repoConfigs: RepoConfigStore(fileURL: dir.appendingPathComponent("prbar.yaml"), lastGoodURL: nil),
            readiness: ReadinessCoordinator(notifier: notifier, store: FileNotifiedSHAStore(stateDirectory: dir)),
            actionLog: ActionLogStore(history: .actions(in: dir)),
            reviewLog: ReviewLogStore(history: ReviewHistory(in: dir)),
            ownsAutomation: ownsAutomation
        )
    }

    private static func requestedPR() -> InboxPR {
        InboxPR(
            nodeId: "PR_1", owner: "o", repo: "r", number: 1,
            title: "t", body: "", url: URL(string: "https://github.com/o/r/pull/1")!,
            author: "a", headRef: "h", baseRef: "main",
            headSha: "abc123", isDraft: false,
            role: .reviewRequested,
            mergeable: "MERGEABLE", mergeStateStatus: "BLOCKED", reviewDecision: nil,
            checkRollupState: "PENDING",
            totalAdditions: 1, totalDeletions: 0, changedFiles: 1,
            hasAutoMerge: false, autoMergeEnabledBy: nil, allCheckSummaries: [],
            allowedMergeMethods: [.squash], autoMergeAllowed: true, deleteBranchOnMerge: true
        )
    }
}

/// A provider that never finishes, so a queued review stays queued.
private struct NeverProvider: ReviewProvider {
    let id = "never"
    let displayName = "Never"
    func availability() async -> ProviderAvailability { .ready }
    func review(
        bundle: PromptBundle,
        options: ProviderOptions,
        onProgress: (@Sendable (ReviewProgress) -> Void)?
    ) async throws -> ProviderResult {
        try await Task.sleep(for: .seconds(3600))
        throw CancellationError()
    }
}
