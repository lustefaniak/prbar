import Foundation
import Observation

struct PollDelta: Sendable, Hashable {
    let added: [InboxPR]
    let removed: [InboxPR]
    let changed: [InboxPR]   // new state of PRs whose previous snapshot differed

    var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && changed.isEmpty
    }

    static let empty = PollDelta(added: [], removed: [], changed: [])
}

@MainActor
@Observable
final class PRPoller {
    private(set) var prs: [InboxPR] = []
    private(set) var lastFetchedAt: Date?
    private(set) var lastError: String?
    private(set) var isFetching: Bool = false
    private(set) var lastDelta: PollDelta?

    /// Interval between scheduled polls. Set freely; the running task picks
    /// up the new value on its next iteration (no need to restart).
    var pollInterval: TimeInterval = 60

    @ObservationIgnored
    private var pollingTask: Task<Void, Never>?

    /// Tracks PR node IDs currently being refreshed individually, so the UI
    /// can show a per-row spinner while a refresh is in flight.
    private(set) var refreshingPRs: Set<String> = []

    /// Tracks PRs currently being merged. Same purpose as refreshingPRs.
    private(set) var mergingPRs: Set<String> = []

    @ObservationIgnored
    private let fetcher: @Sendable () async throws -> [InboxPR]

    @ObservationIgnored
    private let prRefresher: (@Sendable (_ owner: String, _ repo: String, _ number: Int) async throws -> InboxPR)?

    @ObservationIgnored
    private let prMerger: (@Sendable (_ owner: String, _ repo: String, _ number: Int, _ method: MergeMethod) async throws -> Void)?

    @ObservationIgnored
    private let prReviewer: (@Sendable (_ owner: String, _ repo: String, _ number: Int, _ kind: ReviewActionKind, _ body: String) async throws -> Void)?

    /// PRs currently being reviewed (approve/comment/requestChanges). Same
    /// purpose as refreshingPRs / mergingPRs.
    private(set) var postingReviewPRs: Set<String> = []

    /// Optional Notifier; when set, the poller forwards derived events
    /// after each successful poll. Tests typically don't wire one.
    @ObservationIgnored
    weak var notifier: Notifier?

    /// Action history sink. When set, `postReview` and `mergePR` record
    /// one entry per attempt (success and failure both logged).
    @ObservationIgnored
    weak var actionLog: ActionLogStore?

    /// Fires after every successful poll with the latest inbox. Used by
    /// `ReadinessCoordinator` to track which review-requested PRs are
    /// waiting on AI triage versus already ready for the user.
    @ObservationIgnored
    var onPollSuccess: (@MainActor (_ prs: [InboxPR]) -> Void)?

    /// Optional snapshot cache for loading the last known state on launch
    /// and persisting after each successful poll.
    @ObservationIgnored
    private let cache: SnapshotCache?

    init(
        fetcher: @Sendable @escaping () async throws -> [InboxPR],
        prRefresher: (@Sendable (_ owner: String, _ repo: String, _ number: Int) async throws -> InboxPR)? = nil,
        prMerger: (@Sendable (_ owner: String, _ repo: String, _ number: Int, _ method: MergeMethod) async throws -> Void)? = nil,
        prReviewer: (@Sendable (_ owner: String, _ repo: String, _ number: Int, _ kind: ReviewActionKind, _ body: String) async throws -> Void)? = nil,
        cache: SnapshotCache? = nil
    ) {
        self.fetcher = fetcher
        self.prRefresher = prRefresher
        self.prMerger = prMerger
        self.prReviewer = prReviewer
        self.cache = cache
    }

    /// Load the last persisted snapshot (if any) into `prs`. Idempotent —
    /// no-op if `prs` is already populated. Call once early in app launch.
    func loadCached() async {
        guard prs.isEmpty, let cache else { return }
        let cached = await cache.load()
        if !cached.isEmpty {
            self.prs = cached
        }
    }

    /// Convenience constructor backed by a real `GHClient` that auto-starts
    /// the polling loop. Errors at fetch time (gh missing, auth, network)
    /// are surfaced via `lastError`, never thrown from construction.
    static func live() -> PRPoller {
        // Cache one client across calls — instantiation only does an
        // executable path lookup so it's cheap, but no need to repeat.
        let client: GHClient? = try? GHClient()
        let snapshotCache = SnapshotCache()
        let poller = PRPoller(
            fetcher: {
                let c = try client ?? GHClient()
                return try await c.fetchInbox()
            },
            prRefresher: { owner, repo, number in
                let c = try client ?? GHClient()
                return try await c.fetchPR(owner: owner, repo: repo, number: number)
            },
            prMerger: { owner, repo, number, method in
                let c = try client ?? GHClient()
                // Always pass --delete-branch when the repo opts into it
                // server-side. gh ignores the flag if not applicable, so
                // it's safe to leave at the repo's default behavior.
                try await c.mergePR(
                    owner: owner, repo: repo, number: number,
                    method: method, deleteBranch: false
                )
            },
            prReviewer: { owner, repo, number, kind, body in
                let c = try client ?? GHClient()
                try await c.postReview(
                    owner: owner, repo: repo, number: number,
                    kind: kind, body: body
                )
            },
            cache: snapshotCache
        )
        Task { await poller.loadCached() }
        poller.start()
        return poller
    }

    /// Start the polling loop. Idempotent — second call is a no-op.
    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                let interval = self.pollInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Stop the polling loop. Idempotent.
    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Trigger an immediate poll without disturbing the schedule.
    func pollNow() {
        Task { await poll() }
    }

    /// Refresh a single PR via the cheap single-PR query. Replaces the entry
    /// in `prs` in place; the row only "blinks" if the snapshot actually
    /// changed. No-op (with optional fallback to pollNow) if no per-PR
    /// refresher is configured (e.g. in tests using the simpler init).
    func refreshPR(_ pr: InboxPR) {
        let nodeId = pr.nodeId
        let owner = pr.owner
        let repo = pr.repo
        let number = pr.number
        guard let refresher = prRefresher else {
            pollNow()
            return
        }
        guard !refreshingPRs.contains(nodeId) else { return }
        refreshingPRs.insert(nodeId)

        Task {
            defer { refreshingPRs.remove(nodeId) }
            do {
                let updated = try await refresher(owner, repo, number)
                if let idx = self.prs.firstIndex(where: { $0.nodeId == nodeId }) {
                    self.prs[idx] = updated
                }
            } catch {
                self.lastError = error.localizedDescription
            }
        }
    }

    /// Post a review (approve / comment / request changes) on a PR. After
    /// success, refreshes the PR so the row reflects the new
    /// reviewDecision. On failure, surfaces error text in `lastError`.
    func postReview(_ pr: InboxPR, kind: ReviewActionKind, body: String = "") {
        let nodeId = pr.nodeId
        guard let reviewer = prReviewer else { return }
        guard !postingReviewPRs.contains(nodeId) else { return }
        postingReviewPRs.insert(nodeId)

        Task {
            defer { postingReviewPRs.remove(nodeId) }
            do {
                try await reviewer(pr.owner, pr.repo, pr.number, kind, body)
                self.lastError = nil
                self.actionLog?.record(
                    kind: kind.actionLogKind, outcome: .success, pr: pr,
                    detail: body.isEmpty ? nil : body
                )
                self.refreshPR(pr)
            } catch {
                self.lastError = error.localizedDescription
                self.actionLog?.record(
                    kind: kind.actionLogKind, outcome: .failure, pr: pr,
                    errorMessage: error.localizedDescription,
                    detail: body.isEmpty ? nil : body
                )
            }
        }
    }

    /// Merge a PR via gh, then refresh it so the UI reflects the new state
    /// (closed, mergeStateStatus, etc.). On failure, surfaces error text in
    /// `lastError` and the row stays in the list.
    func mergePR(_ pr: InboxPR, method: MergeMethod = .squash) {
        let nodeId = pr.nodeId
        let owner = pr.owner
        let repo = pr.repo
        let number = pr.number
        guard let merger = prMerger else { return }
        guard pr.allowedMergeMethods.contains(method) else {
            self.lastError = "\(method.displayName) is disabled on \(pr.nameWithOwner)."
            return
        }
        guard !mergingPRs.contains(nodeId) else { return }
        mergingPRs.insert(nodeId)

        Task {
            defer { mergingPRs.remove(nodeId) }
            do {
                try await merger(owner, repo, number, method)
                self.lastError = nil
                self.actionLog?.record(
                    kind: .merge, outcome: .success, pr: pr,
                    detail: method.rawValue
                )
                self.refreshPR(pr)
            } catch {
                self.lastError = error.localizedDescription
                self.actionLog?.record(
                    kind: .merge, outcome: .failure, pr: pr,
                    errorMessage: error.localizedDescription,
                    detail: method.rawValue
                )
            }
        }
    }

    /// Test/preview only: directly assign the inbox without going
    /// through the polling loop. Used by ScreenshotTests to render
    /// deterministic fixture states.
    func _setPRsForScreenshot(_ prs: [InboxPR]) {
        self.prs = prs
        self.lastFetchedAt = Date()
    }

    private func poll() async {
        isFetching = true
        defer { isFetching = false }

        do {
            let fetched = try await fetcher()
            let oldPRs = self.prs
            self.prs = fetched
            let delta = Self.computeDelta(old: oldPRs, new: fetched)
            self.lastDelta = delta
            self.lastFetchedAt = Date()
            self.lastError = nil

            // Skip notifications on the very first successful poll — we
            // don't want to wake the user with "5 PRs are ready to merge!"
            // every time the app launches.
            if !oldPRs.isEmpty, let notifier {
                let events = EventDeriver.events(from: delta, oldPRs: oldPRs)
                notifier.enqueue(events)
            }

            // Always fire — the coordinator owns its own first-poll logic
            // and needs to see every poll to track membership transitions
            // (PR drops out of inbox).
            onPollSuccess?(fetched)

            // Persist asynchronously; don't block the poll on disk I/O.
            if let cache {
                Task.detached { await cache.save(fetched) }
            }
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    static func computeDelta(old: [InboxPR], new: [InboxPR]) -> PollDelta {
        let oldById = Dictionary(uniqueKeysWithValues: old.map { ($0.nodeId, $0) })
        let newById = Dictionary(uniqueKeysWithValues: new.map { ($0.nodeId, $0) })

        let added = new.filter { oldById[$0.nodeId] == nil }
        let removed = old.filter { newById[$0.nodeId] == nil }
        let changed = new.filter { newPR in
            guard let oldPR = oldById[newPR.nodeId] else { return false }
            return oldPR != newPR
        }
        return PollDelta(added: added, removed: removed, changed: changed)
    }
}
