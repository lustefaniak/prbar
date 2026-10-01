import Foundation

/// The app's production wiring of the core services: real `gh`, the
/// app's file locations (`AppPaths`, which point at a throwaway directory
/// under XCTest), and the read-only fallbacks into the pre-file SwiftData
/// store. The services themselves live in PRBarCore and know none of this.
extension ReviewQueueWorker {
    /// Real GHClient-backed worker with a real checkout manager.
    /// `actionLog` / `reviewLog` are wired separately by AppDelegate, which
    /// shares them with the views.
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
    }
}

extension FailureLogStore: CIFailureTailing {}

extension ActionLogStore: ActionLogging {}

extension ReviewLogStore: ReviewLogging {}

extension PRPoller {
    /// Real `GHClient`, auto-started. Errors at fetch time (gh missing,
    /// auth, network) are surfaced via `lastError`, never thrown from
    /// construction.
    static func live() -> PRPoller {
        // Cache one client across calls — instantiation only does an
        // executable path lookup so it's cheap, but no need to repeat.
        let client: GHClient? = try? GHClient()
        var legacy: (@Sendable () -> [InboxPR]?)?
        if AppPaths.readsLegacyStore {
            legacy = { LegacyStateMigration.inboxSnapshot(PRBarModelContainer.live()) }
        }
        let snapshotCache = SnapshotCache(stateDirectory: AppPaths.state, fallback: legacy)
        let poller = PRPoller(
            fetcher: {
                let c = try client ?? GHClient()
                return try await c.fetchInbox()
            },
            prRefresher: { owner, repo, number in
                let c = try client ?? GHClient()
                return try await c.fetchPR(owner: owner, repo: repo, number: number)
            },
            cache: snapshotCache
        )
        poller.loadCached()
        poller.start()
        return poller
    }
}

extension DiffStore {
    /// Reuse a `ReviewQueueWorker`'s injected fetcher so we don't spin up
    /// a second `GHClient`; parsed diffs survive relaunches on disk.
    static func sharing(_ worker: ReviewQueueWorker) -> DiffStore {
        DiffStore(diffFetcher: worker.diffFetcher, cache: FileCache(directory: AppPaths.cache.appendingPathComponent("diffs")))
    }
}

extension FailureLogStore {
    /// Constructing a fresh client per call keeps the store's init
    /// non-throwing — if `gh` isn't installed the first fetch surfaces a
    /// `.failed` state instead of crashing the app.
    static func live() -> FailureLogStore {
        FailureLogStore(
            logFetcher: { owner, repo, jobId in
                let c = try GHClient()
                return try await c.fetchJobLog(owner: owner, repo: repo, jobId: jobId)
            },
            cache: FileCache(directory: AppPaths.cache.appendingPathComponent("ci-logs"))
        )
    }
}

extension RepoConfigStore {
    /// The user's config file, migrated from the SwiftData + UserDefaults
    /// settings on first launch, watched for edits.
    static func live() -> RepoConfigStore {
        RepoConfigStore(
            legacy: { LegacyConfigMigration.read(container: PRBarModelContainer.live(), userDefaults: .standard) },
            watch: true
        )
    }
}

extension ReadinessCoordinator {
    /// Which `(PR, head SHA)` pairs already got a "ready for review"
    /// banner, in `<state>/notified.json`; until that file exists, the map
    /// the app kept in UserDefaults, so an upgrade doesn't re-ping them.
    static func live(notifier: Notifier) -> ReadinessCoordinator {
        var legacy: (@Sendable () -> [String: String]?)?
        if AppPaths.readsLegacyStore {
            legacy = {
                UserDefaults.standard.data(forKey: "readinessNotifiedSHAs")
                    .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
            }
        }
        return ReadinessCoordinator(
            notifier: notifier,
            store: FileNotifiedSHAStore(stateDirectory: AppPaths.state, fallback: legacy)
        )
    }
}
