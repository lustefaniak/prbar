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

    @ObservationIgnored
    private let fetcher: @Sendable () async throws -> [InboxPR]

    init(fetcher: @Sendable @escaping () async throws -> [InboxPR]) {
        self.fetcher = fetcher
    }

    /// Convenience constructor backed by a real `GHClient`. Errors at fetch
    /// time (gh missing, auth, network) are surfaced via `lastError`, never
    /// thrown from construction.
    static func live() -> PRPoller {
        PRPoller(fetcher: {
            let client = try GHClient()
            return try await client.fetchInbox()
        })
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

    private func poll() async {
        isFetching = true
        defer { isFetching = false }

        do {
            let fetched = try await fetcher()
            let oldPRs = self.prs
            self.prs = fetched
            self.lastDelta = Self.computeDelta(old: oldPRs, new: fetched)
            self.lastFetchedAt = Date()
            self.lastError = nil
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
