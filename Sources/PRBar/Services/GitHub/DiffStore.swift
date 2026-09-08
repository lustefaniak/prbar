import Foundation
import Observation
import SwiftData

/// Cache of parsed unified diffs, keyed by (prNodeId, headSha) so a
/// force-push automatically invalidates. Used by `PRDetailView` to load
/// the diff lazily when a PR is opened.
///
/// Hits hydrate from SwiftData on first lookup; misses fetch via the
/// injected `diffFetcher` and write through on success. Transient
/// `.loading` / `.failed` states stay in memory only — there's no point
/// persisting them.
@MainActor
@Observable
final class DiffStore {
    enum LoadStatus: Sendable, Hashable {
        case idle
        case loading
        case loaded([Hunk])
        case failed(String)

        var isTerminal: Bool {
            switch self {
            case .loaded, .failed: return true
            case .idle, .loading:  return false
            }
        }
    }

    private(set) var statuses: [String: LoadStatus] = [:]   // key = "<prNodeId>@<headSha>"

    @ObservationIgnored
    var diffFetcher: @Sendable (_ owner: String, _ repo: String, _ number: Int) async throws -> String

    @ObservationIgnored
    private let container: ModelContainer?

    init(
        diffFetcher: @escaping @Sendable (_ owner: String, _ repo: String, _ number: Int) async throws -> String,
        container: ModelContainer? = nil
    ) {
        self.diffFetcher = diffFetcher
        self.container = container
    }

    /// Reuse a `ReviewQueueWorker`'s injected fetcher so we don't spin up
    /// a second `GHClient`. Production callsite — wires the shared
    /// SwiftData container so the parsed diff survives relaunches.
    static func sharing(_ worker: ReviewQueueWorker) -> DiffStore {
        DiffStore(diffFetcher: worker.diffFetcher, container: PRBarModelContainer.live())
    }

    /// In-memory read only — never touches disk. Called from view bodies,
    /// where a SQLite fetch plus a multi-MB JSON decode would land on the
    /// main actor. Disk hydration happens asynchronously in `ensureLoaded`,
    /// which every call site already pairs this with.
    func status(for pr: InboxPR) -> LoadStatus {
        statuses[key(for: pr)] ?? .idle
    }

    /// Fetch (and parse) the diff if we don't already have it. Idempotent
    /// — calling while loading is a no-op; calling after success is a no-op.
    /// A prior failure is retried.
    func ensureLoaded(for pr: InboxPR) {
        let k = key(for: pr)
        if let s = statuses[k] {
            switch s {
            case .loading, .loaded: return
            case .idle, .failed: break
            }
        }
        statuses[k] = .loading
        Task { [weak self, fetcher = diffFetcher, container] in
            // Disk hit first, so re-opening a PR loaded in a prior session
            // doesn't re-run `gh pr diff`. Both the SQLite read and the JSON
            // decode go off the main actor: the PR list prefetches a dozen
            // PRs at once and the payloads run to megabytes.
            if let hunks = await Task.detached(operation: {
                Self.readPersisted(container, cacheKey: k)
            }).value {
                self?.statuses[k] = .loaded(hunks)
                return
            }
            do {
                let raw = try await fetcher(pr.owner, pr.repo, pr.number)
                let hunks = await Task.detached(operation: { DiffParser.parse(raw) }).value
                self?.statuses[k] = .loaded(hunks)
                Task.detached { Self.writePersisted(container, cacheKey: k, hunks: hunks) }
            } catch {
                self?.statuses[k] = .failed(error.localizedDescription)
            }
        }
    }

    /// Test/preview only: pre-populate parsed hunks so screenshots can
    /// render the diff section without a real `gh pr diff` call.
    func _setLoadedForScreenshot(pr: InboxPR, hunks: [Hunk]) {
        statuses[key(for: pr)] = .loaded(hunks)
    }

    /// Drop the cached diff (e.g. on Re-run after a force-push).
    func invalidate(for pr: InboxPR) {
        let k = key(for: pr)
        statuses[k] = .idle
        Task.detached { [container] in Self.deletePersisted(container, cacheKey: k) }
    }

    private func key(for pr: InboxPR) -> String {
        "\(pr.nodeId)@\(pr.headSha)"
    }

    // MARK: - SwiftData

    // `nonisolated static` so these run off the main actor. A `ModelContext`
    // built and discarded inside one call never escapes, which is what makes
    // the Sendable `ModelContainer` safe to hand to a detached task.

    nonisolated private static func readPersisted(
        _ container: ModelContainer?, cacheKey: String
    ) -> [Hunk]? {
        guard let container else { return nil }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<DiffCacheEntry>(
            predicate: #Predicate { $0.cacheKey == cacheKey }
        )
        guard let row = (try? context.fetch(descriptor))?.first else { return nil }
        return try? JSONDecoder().decode([Hunk].self, from: row.payload)
    }

    nonisolated private static func writePersisted(
        _ container: ModelContainer?, cacheKey: String, hunks: [Hunk]
    ) {
        guard let container else { return }
        guard let payload = try? JSONEncoder().encode(hunks) else { return }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<DiffCacheEntry>(
            predicate: #Predicate { $0.cacheKey == cacheKey }
        )
        if let row = (try? context.fetch(descriptor))?.first {
            row.payload = payload
            row.savedAt = Date()
        } else {
            context.insert(DiffCacheEntry(cacheKey: cacheKey, payload: payload, savedAt: Date()))
        }
        try? context.save()
    }

    nonisolated private static func deletePersisted(
        _ container: ModelContainer?, cacheKey: String
    ) {
        guard let container else { return }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<DiffCacheEntry>(
            predicate: #Predicate { $0.cacheKey == cacheKey }
        )
        if let row = (try? context.fetch(descriptor))?.first {
            context.delete(row)
            try? context.save()
        }
    }
}
