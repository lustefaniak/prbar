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

    func status(for pr: InboxPR) -> LoadStatus {
        let k = key(for: pr)
        if let s = statuses[k] { return s }
        // Cold lookup: hydrate from disk if we have a hit.
        if let hunks = readPersisted(cacheKey: k) {
            statuses[k] = .loaded(hunks)
            return .loaded(hunks)
        }
        return .idle
    }

    /// Fetch (and parse) the diff if we don't already have it. Idempotent
    /// — calling while loading is a no-op; calling after success is a no-op.
    func ensureLoaded(for pr: InboxPR) {
        let k = key(for: pr)
        // Hydrate from disk first; avoids a needless fetch when the user
        // re-opens a PR they already loaded in a prior session.
        if statuses[k] == nil, let hunks = readPersisted(cacheKey: k) {
            statuses[k] = .loaded(hunks)
            return
        }
        if let s = statuses[k], s != .idle, case .failed = s { /* allow retry */ }
        else if let s = statuses[k], s != .idle { return }

        statuses[k] = .loading
        Task { [weak self, fetcher = diffFetcher] in
            do {
                let raw = try await fetcher(pr.owner, pr.repo, pr.number)
                let hunks = DiffParser.parse(raw)
                await MainActor.run {
                    self?.statuses[k] = .loaded(hunks)
                    self?.writePersisted(cacheKey: k, hunks: hunks)
                }
            } catch {
                await MainActor.run {
                    self?.statuses[k] = .failed(error.localizedDescription)
                }
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
        deletePersisted(cacheKey: k)
    }

    private func key(for pr: InboxPR) -> String {
        "\(pr.nodeId)@\(pr.headSha)"
    }

    // MARK: - SwiftData

    private func readPersisted(cacheKey: String) -> [Hunk]? {
        guard let container else { return nil }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<DiffCacheEntry>(
            predicate: #Predicate { $0.cacheKey == cacheKey }
        )
        guard let row = (try? context.fetch(descriptor))?.first else { return nil }
        return try? JSONDecoder().decode([Hunk].self, from: row.payload)
    }

    private func writePersisted(cacheKey: String, hunks: [Hunk]) {
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

    private func deletePersisted(cacheKey: String) {
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
