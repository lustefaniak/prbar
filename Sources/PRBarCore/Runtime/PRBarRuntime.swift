import Foundation

extension ActionLogStore: ActionLogging {}

extension ReviewLogStore: ReviewLogging {}

extension FailureLogStore: CIFailureTailing {}

/// Everything PRBar does without a UI, wired together: polling, AI review,
/// the GitHub write queue, readiness notifications, history and config.
/// The menu-bar app is one front end over it (`AppDelegate` exposes these
/// services to SwiftUI); `prbar-review watch` is another, with no UI at all.
///
/// The init does only wiring, so a caller can hand in inert services (the
/// app's screenshot mode) and get the same behaviour between them.
@MainActor
final class PRBarRuntime {
    let poller: PRPoller
    let notifier: Notifier
    let queue: ReviewQueueWorker
    let actionQueue: ActionQueue
    let diffStore: DiffStore
    let failureLogs: FailureLogStore
    let repoConfigs: RepoConfigStore
    let readiness: ReadinessCoordinator
    let actionLog: ActionLogStore
    let reviewLog: ReviewLogStore

    /// Whether this process starts AI reviews and posts on its own. False
    /// when another PRBar runtime on this machine holds the runtime lock:
    /// both would otherwise review the same PRs as the same user and post
    /// twice. Polling, the UI and manual actions keep working either way.
    var ownsAutomation: Bool

    /// What happened, for anyone outside the runtime that needs to follow
    /// along (the API server, `watch`'s log). The service hooks themselves
    /// are single closures owned by `wire()`; observing here never
    /// replaces them.
    enum Event {
        case inboxChanged([InboxPR])
        case reviewSettled(prNodeId: String)
        case actionCompleted(InboxPR)
        case configChanged
    }

    private var observers: [UUID: @MainActor (Event) -> Void] = [:]

    @discardableResult
    func observe(_ observer: @escaping @MainActor (Event) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func emit(_ event: Event) {
        for observer in observers.values { observer(event) }
    }

    init(
        poller: PRPoller,
        notifier: Notifier,
        queue: ReviewQueueWorker,
        actionQueue: ActionQueue,
        diffStore: DiffStore,
        failureLogs: FailureLogStore,
        repoConfigs: RepoConfigStore,
        readiness: ReadinessCoordinator,
        actionLog: ActionLogStore,
        reviewLog: ReviewLogStore,
        ownsAutomation: Bool = true
    ) {
        self.poller = poller
        self.notifier = notifier
        self.queue = queue
        self.actionQueue = actionQueue
        self.diffStore = diffStore
        self.failureLogs = failureLogs
        self.repoConfigs = repoConfigs
        self.readiness = readiness
        self.actionLog = actionLog
        self.reviewLog = reviewLog
        self.ownsAutomation = ownsAutomation
        wire()
    }

    // MARK: - Maintenance

    private var maintenanceTask: Task<Void, Never>?

    /// Evicts aged-out history and cache files and stale review worktrees,
    /// now and then once a day. Any host runs it: a server that stays up for
    /// weeks needs it as much as an app relaunched every morning.
    func startMaintenance(cacheDirectory: URL, every interval: Duration = .seconds(24 * 60 * 60)) {
        maintenanceTask?.cancel()
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runMaintenance(cacheDirectory: cacheDirectory)
                try? await Task.sleep(for: interval)
            }
        }
    }

    func runMaintenance(cacheDirectory: URL, now: Date = Date()) async {
        // A directory walk, so off the main actor.
        await Task.detached { StoreRetention.sweepCaches(in: cacheDirectory, now: now) }.value
        actionLog.prune(before: now.addingTimeInterval(-StoreRetention.actionLog))
        reviewLog.prune(before: now.addingTimeInterval(-StoreRetention.reviewLog))
        queue.ruleLog?.prune(before: now.addingTimeInterval(-StoreRetention.ruleLog))
        await queue.checkoutManager?.sweepStaleWorktrees()
    }

    private func wire() {
        let p = poller, q = queue, a = actionQueue, rc = repoConfigs, coord = readiness

        q.failureLogStore = failureLogs
        q.actionLog = actionLog
        q.reviewLog = reviewLog
        a.actionLog = actionLog

        // Every successful gh write refreshes the PR through the poller.
        // GitHub's GraphQL read-model lags the REST write, so refresh now
        // for the optimistic intermediate state and again after ~1.2s as a
        // belt-and-suspenders catch for the propagation.
        a.onActionCompleted = { [weak self, weak p] pr in
            self?.emit(.actionCompleted(pr))
            p?.refreshPR(pr)
            Task { @MainActor [weak p] in
                try? await Task.sleep(for: .seconds(1.2))
                p?.refreshPR(pr, force: true)
            }
        }
        // Auto-review posts route through the ActionQueue so they share
        // the one serialized + dedup'd + retryable + logged write path.
        q.enqueueAutoReview = { [weak a] pr, kind, body, comments, cost, source in
            a?.enqueue(
                pr,
                kind: .review(kind: kind, body: body, comments: comments),
                source: source,
                costUsd: cost
            )
        }
        // Thread resolution is a GitHub write like any other, so it takes
        // the same queued path rather than firing from the worker.
        q.enqueueResolveThreads = { [weak a] pr, threadIds in
            a?.enqueue(pr, kind: .resolveThreads(ids: threadIds), source: .automated)
        }

        q.configResolver = rc.makeResolver()
        p.configResolver = rc.makeResolver()
        rc.noteRepositories(p.prs)
        // Provider / model / effort defaults come from prbar.yaml. "auto"
        // resolves to whichever CLI is installed (claude wins ties).
        rc.config.applyAgentDefaults(to: q)
        rc.onChange = { [weak self, weak q, weak rc, weak p] in
            guard let q, let rc else { return }
            self?.emit(.configChanged)
            q.configResolver = rc.makeResolver()
            p?.configResolver = rc.makeResolver()
            rc.config.applyAgentDefaults(to: q)
            // Re-poll so the title-exclude filter applies to anything in
            // the inbox right now, not just future fetches.
            p?.pollNow()
        }

        // Hand AI-triage settlement to the coordinator so it can flip the
        // per-PR ready bit and (when the queue idles) flush a batched
        // "ready for review" notification.
        q.onReviewSettled = { [weak self, weak coord] prNodeId, isWorkerSettled in
            coord?.noteReviewSettled(prNodeId: prNodeId, isWorkerSettled: isWorkerSettled)
            self?.emit(.reviewSettled(prNodeId: prNodeId))
        }
        // Feed each successful poll into the coordinator so it can spot
        // newly-arrived review-requested PRs and forget ones that left the
        // inbox, and start AI triage straight away for new requests.
        p.onPollSuccess = { [weak self, weak coord, weak rc, weak q] prs in
            guard let coord, let rc else { return }
            rc.noteRepositories(prs)
            coord.track(prs: prs, configResolver: rc.resolve(owner:repo:))
            if self?.ownsAutomation ?? false {
                q?.enqueueNewReviewRequests(from: prs)
            }
            self?.emit(.inboxChanged(prs))
        }
        p.notifier = notifier
    }
}

/// Where a runtime keeps its files, and what it may fall back to while a
/// file doesn't exist yet. The app fills the fallbacks from its legacy
/// SwiftData store; the headless runtime has none.
struct RuntimeEnvironment {
    var configFile: URL
    var lastGoodConfig: URL?
    var stateDirectory: URL
    var cacheDirectory: URL
    var watchConfig = true

    var legacyConfig: (@MainActor () -> PRBarConfig?)?
    var legacyReviewStates: (@Sendable () -> [String: ReviewState]?)?
    var legacyInbox: (@Sendable () -> [InboxPR]?)?
    var legacyNotified: (@Sendable () -> [String: String]?)?

    var historyDirectory: URL { stateDirectory.appendingPathComponent("history") }

    /// Writes the files a runtime would otherwise read through the legacy
    /// fallbacks (config, review state, inbox, notified SHAs), so a server
    /// with no fallbacks of its own, such as one in another process, starts
    /// from the same state. Leaves any file that exists alone.
    @MainActor
    func materializeLegacyFiles() {
        let fm = FileManager.default
        if let legacyConfig, !fm.fileExists(atPath: configFile.path) {
            // Constructing the store migrates: it writes what `legacyConfig`
            // returns as the new file.
            _ = RepoConfigStore(fileURL: configFile, lastGoodURL: lastGoodConfig, legacy: legacyConfig)
        }
        func write<Value: Codable & Sendable>(_ name: String, _ fallback: (@Sendable () -> Value?)?) {
            let file = JSONStateFile<Value>(url: stateDirectory.appendingPathComponent(name))
            guard !fm.fileExists(atPath: file.url.path), let value = fallback?() else { return }
            file.save(value)
        }
        write("review-state.json", legacyReviewStates)
        write("inbox.json", legacyInbox)
        write("notified.json", legacyNotified)
    }

    /// The XDG locations the CLI and the app share by default.
    static func standard(configFile: URL = ConfigLocation.userConfigURL()) -> RuntimeEnvironment {
        RuntimeEnvironment(
            configFile: configFile,
            lastGoodConfig: ConfigLocation.lastGoodURL(),
            stateDirectory: ConfigLocation.stateDirectory(),
            cacheDirectory: CacheLocation.directory()
        )
    }
}

extension PRBarRuntime {
    /// The production runtime: real `gh`, files under `environment`, the
    /// poller started. Nothing here is macOS-specific.
    static func live(
        _ environment: RuntimeEnvironment,
        deliverer: NotificationDeliverer,
        ownsAutomation: Bool = true
    ) -> PRBarRuntime {
        let client = try? GHClient()
        let notifier = Notifier(deliverer: deliverer)

        let failureLogs = FailureLogStore(
            logFetcher: { owner, repo, jobId in
                let c = try client ?? GHClient()
                return try await c.fetchJobLog(owner: owner, repo: repo, jobId: jobId)
            },
            cache: FileCache(directory: environment.cacheDirectory.appendingPathComponent("ci-logs"))
        )
        let queue = ReviewQueueWorker(
            diffFetcher: { owner, repo, number in
                let c = try client ?? GHClient()
                return try await c.fetchDiff(owner: owner, repo: repo, number: number)
            },
            checkoutManager: RepoCheckoutManager(),
            cache: ReviewStateFile(stateDirectory: environment.stateDirectory, fallback: environment.legacyReviewStates),
            failureLogStore: failureLogs
        )
        queue.ruleLog = .rules(in: environment.historyDirectory)
        queue.reviewThreadFetcher = { owner, repo, number in
            let c = try client ?? GHClient()
            return try await c.fetchReviewThreads(owner: owner, repo: repo, number: number)
        }
        queue.repoRulesFetcher = { owner, repo in
            try await (client ?? GHClient()).fetchRepoRules(owner: owner, repo: repo)
        }
        queue.lazyFactFetcher = LazyFactFetcher(committers: { owner, repo, number in
            try await (client ?? GHClient()).fetchCommitters(owner: owner, repo: repo, number: number)
        })
        let poller = PRPoller(
            fetcher: {
                let c = try client ?? GHClient()
                return try await c.fetchInbox()
            },
            prRefresher: { owner, repo, number in
                let c = try client ?? GHClient()
                return try await c.fetchPR(owner: owner, repo: repo, number: number)
            },
            cache: SnapshotCache(stateDirectory: environment.stateDirectory, fallback: environment.legacyInbox)
        )
        let runtime = PRBarRuntime(
            poller: poller,
            notifier: notifier,
            queue: queue,
            actionQueue: ActionQueue.live(),
            diffStore: DiffStore(
                diffFetcher: queue.diffFetcher,
                cache: FileCache(directory: environment.cacheDirectory.appendingPathComponent("diffs"))
            ),
            failureLogs: failureLogs,
            repoConfigs: RepoConfigStore(
                fileURL: environment.configFile,
                lastGoodURL: environment.lastGoodConfig,
                legacy: environment.legacyConfig,
                watch: environment.watchConfig
            ),
            readiness: ReadinessCoordinator(
                notifier: notifier,
                store: FileNotifiedSHAStore(stateDirectory: environment.stateDirectory, fallback: environment.legacyNotified)
            ),
            actionLog: ActionLogStore(history: .actions(in: environment.historyDirectory)),
            reviewLog: ReviewLogStore(history: ReviewHistory(in: environment.historyDirectory)),
            ownsAutomation: ownsAutomation
        )
        poller.loadCached()
        poller.start()
        return runtime
    }
}
