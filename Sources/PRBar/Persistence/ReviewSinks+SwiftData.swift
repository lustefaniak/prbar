import Foundation

/// SwiftData-backed conformances to the review pipeline's persistence
/// seams, plus the `live()` convenience that wires them. App-only: the
/// core library declares the protocols and runs fine with all four nil,
/// which is what the headless CLI does.
extension ReviewCache: ReviewStateCaching {}

extension FailureLogStore: CIFailureTailing {}

extension ActionLogStore: ActionLogging {}

extension ReviewLogStore: ReviewLogging {}

extension ReviewQueueWorker {
    /// Convenience: real GHClient-backed worker with a real checkout manager.
    static func live() -> ReviewQueueWorker {
        let client = try? GHClient()
        let checkout = RepoCheckoutManager()
        let worker = ReviewQueueWorker(
            diffFetcher: { owner, repo, number in
                let c = try client ?? GHClient()
                return try await c.fetchDiff(owner: owner, repo: repo, number: number)
            },
            checkoutManager: checkout,
            cache: ReviewCache.live(),
            failureLogStore: FailureLogStore.live()
        )
        worker.reviewThreadFetcher = { owner, repo, number in
            let c = try client ?? GHClient()
            return try await c.fetchReviewThreads(owner: owner, repo: repo, number: number)
        }
        return worker
        // reviewLog is wired separately by AppDelegate so all stores
        // share one ModelContainer (sharing the container keeps SwiftData
        // notifications consistent across @Query consumers).
    }
}
