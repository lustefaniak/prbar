import Foundation

/// The app's conformances to the review pipeline's persistence seams,
/// plus the `live()` convenience that wires them. The core library
/// declares the protocols and runs fine with all four nil, which is what
/// the headless CLI does.
extension FailureLogStore: CIFailureTailing {}

extension ActionLogStore: ActionLogging {}

extension ReviewLogStore: ReviewLogging {}

extension ReviewQueueWorker {
    /// Convenience: real GHClient-backed worker with a real checkout manager.
    static func live() -> ReviewQueueWorker {
        let client = try? GHClient()
        let checkout = RepoCheckoutManager()
        var legacy: (@Sendable () -> [String: ReviewState]?)?
        if AppPaths.readsLegacyStore {
            legacy = { LegacyStateMigration.reviewStates(PRBarModelContainer.live()) }
        }
        let worker = ReviewQueueWorker(
            diffFetcher: { owner, repo, number in
                let c = try client ?? GHClient()
                return try await c.fetchDiff(owner: owner, repo: repo, number: number)
            },
            checkoutManager: checkout,
            cache: ReviewStateFile(stateDirectory: AppPaths.state, fallback: legacy),
            failureLogStore: FailureLogStore.live()
        )
        worker.reviewThreadFetcher = { owner, repo, number in
            let c = try client ?? GHClient()
            return try await c.fetchReviewThreads(owner: owner, repo: repo, number: number)
        }
        return worker
        // actionLog / reviewLog are wired separately by AppDelegate, which
        // shares them with the views.
    }
}
