import Foundation
import Observation

/// In-memory cache of parsed unified diffs, keyed by (prNodeId, headSha)
/// so a force-push automatically invalidates. Used by `PRDetailView` to
/// load the diff lazily when a PR is opened.
///
/// Disk persistence is a follow-up (see PLAN.md `DiffCache`); for the
/// menu-bar lifetime this is fine — diffs re-fetch in <1 s typically.
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

    init(diffFetcher: @escaping @Sendable (_ owner: String, _ repo: String, _ number: Int) async throws -> String) {
        self.diffFetcher = diffFetcher
    }

    /// Reuse a `ReviewQueueWorker`'s injected fetcher so we don't spin up
    /// a second `GHClient`.
    static func sharing(_ worker: ReviewQueueWorker) -> DiffStore {
        DiffStore(diffFetcher: worker.diffFetcher)
    }

    func status(for pr: InboxPR) -> LoadStatus {
        statuses[key(for: pr)] ?? .idle
    }

    /// Fetch (and parse) the diff if we don't already have it. Idempotent
    /// — calling while loading is a no-op; calling after success is a no-op.
    func ensureLoaded(for pr: InboxPR) {
        let k = key(for: pr)
        if let s = statuses[k], s != .idle, case .failed = s { /* allow retry */ }
        else if let s = statuses[k], s != .idle { return }

        statuses[k] = .loading
        Task { [weak self, fetcher = diffFetcher] in
            do {
                let raw = try await fetcher(pr.owner, pr.repo, pr.number)
                let hunks = DiffParser.parse(raw)
                await MainActor.run { self?.statuses[k] = .loaded(hunks) }
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
        statuses[key(for: pr)] = .idle
    }

    private func key(for pr: InboxPR) -> String {
        "\(pr.nodeId)@\(pr.headSha)"
    }
}
