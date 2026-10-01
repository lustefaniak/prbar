import Foundation
import Observation

/// Cache of parsed unified diffs, keyed by (prNodeId, headSha) so a
/// force-push automatically invalidates. Used by `PRDetailView` to load
/// the diff lazily when a PR is opened.
///
/// Hits hydrate from the on-disk cache (`~/.cache/prbar/diffs`) on first lookup; misses fetch via the
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

    /// Keys whose next `ensureLoaded` must bypass disk hydration — see
    /// `invalidate(for:)`. Cleared as soon as that load starts.
    @ObservationIgnored
    private var invalidatedKeys: Set<String> = []

    @ObservationIgnored
    var diffFetcher: @Sendable (_ owner: String, _ repo: String, _ number: Int) async throws -> String

    @ObservationIgnored
    private let cache: FileCache?

    init(
        diffFetcher: @escaping @Sendable (_ owner: String, _ repo: String, _ number: Int) async throws -> String,
        cache: FileCache? = nil
    ) {
        self.diffFetcher = diffFetcher
        self.cache = cache
    }

    /// In-memory read only — never touches disk. Called from view bodies,
    /// where a file read plus a multi-MB JSON decode would land on the
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
        // A key the caller just invalidated must come from the network, not
        // from the row the detached delete may not have removed yet.
        let mayHydrateFromDisk = !invalidatedKeys.contains(k)
        invalidatedKeys.remove(k)
        Task { [weak self, fetcher = diffFetcher, cache] in
            // Disk hit first, so re-opening a PR loaded in a prior session
            // doesn't re-run `gh pr diff`. Both the file read and the JSON
            // decode go off the main actor: the PR list prefetches a dozen
            // PRs at once and the payloads run to megabytes.
            if mayHydrateFromDisk, let hunks = await Task.detached(operation: {
                Self.readPersisted(cache, cacheKey: k)
            }).value {
                self?.statuses[k] = .loaded(hunks)
                return
            }
            do {
                let raw = try await fetcher(pr.owner, pr.repo, pr.number)
                let hunks = await Task.detached(operation: { DiffParser.parse(raw) }).value
                self?.statuses[k] = .loaded(hunks)
                Task.detached { Self.writePersisted(cache, cacheKey: k, hunks: hunks) }
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
    ///
    /// The disk delete is detached, so it does not race the reload that
    /// always follows: `ensureLoaded` consults `invalidatedKeys` and skips
    /// hydration outright rather than depending on the delete winning. It
    /// did not, reliably — both are unordered detached tasks, and when the
    /// read won, "Reload diff" re-hydrated the exact row it had just
    /// invalidated and returned without calling `gh pr diff`. The stale
    /// hunks then also decided which annotations could be posted inline.
    func invalidate(for pr: InboxPR) {
        let k = key(for: pr)
        statuses[k] = .idle
        invalidatedKeys.insert(k)
        Task.detached { [cache] in cache?.delete(k) }
    }

    private func key(for pr: InboxPR) -> String {
        "\(pr.nodeId)@\(pr.headSha)"
    }

    // MARK: - disk

    // `nonisolated static` so the read and the decode run off the main actor.

    nonisolated private static func readPersisted(_ cache: FileCache?, cacheKey: String) -> [Hunk]? {
        guard let data = cache?.read(cacheKey) else { return nil }
        return try? JSONDecoder().decode([Hunk].self, from: data)
    }

    nonisolated private static func writePersisted(_ cache: FileCache?, cacheKey: String, hunks: [Hunk]) {
        guard let cache, let payload = try? JSONEncoder().encode(hunks) else { return }
        cache.write(cacheKey, payload)
    }
}
