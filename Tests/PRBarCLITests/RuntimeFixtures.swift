import Foundation
@testable import PRBarCore

/// A runtime with every outside dependency stubbed: no gh, a provider that
/// never finishes, files in `dir`. Every poll returns `prs`, which are also
/// in the inbox from the start.
enum RuntimeFixtures {
    static let diff = "diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n@@ -0,0 +1 @@\n+x\n"

    @MainActor
    static func make(_ dir: URL, ownsAutomation: Bool, prs: [InboxPR] = []) -> PRBarRuntime {
        let notifier = Notifier(deliverer: StderrDeliverer())
        let queue = ReviewQueueWorker(diffFetcher: { _, _, _ in diff })
        queue.providerLookup = { _ in NeverProvider() }
        let poller = PRPoller(fetcher: { prs })
        poller._setPRsForScreenshot(prs)
        return PRBarRuntime(
            poller: poller,
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

    static func requestedPR(nodeId: String = "PR_1", number: Int = 1) -> InboxPR {
        InboxPR(
            nodeId: nodeId, owner: "o", repo: "r", number: number,
            title: "t", body: "", url: URL(string: "https://github.com/o/r/pull/\(number)")!,
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
struct NeverProvider: ReviewProvider {
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
