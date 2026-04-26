import Foundation
import Observation

/// On-demand cache of failed Actions job logs. Mirrors `DiffStore`'s
/// shape so `PRDetailView` can show inline expandable failure logs
/// without round-tripping through GitHub on every disclosure toggle.
/// Keyed by `(prNodeId, headSha, jobId)` so a force-push or job re-run
/// (which mints a fresh jobId) auto-invalidates the cache.
@MainActor
@Observable
final class FailureLogStore {
    enum LoadStatus: Sendable, Hashable {
        case idle
        case loading
        case loaded(String)        // tailed log, timestamps stripped
        case failed(String)
    }

    private(set) var statuses: [String: LoadStatus] = [:]

    @ObservationIgnored
    var logFetcher: @Sendable (_ owner: String, _ repo: String, _ jobId: Int64) async throws -> String

    init(logFetcher: @escaping @Sendable (_ owner: String, _ repo: String, _ jobId: Int64) async throws -> String) {
        self.logFetcher = logFetcher
    }

    /// Default wiring against the shared `GHClient`. Constructing a
    /// fresh client per call keeps the store's init non-throwing — if
    /// `gh` isn't installed the first fetch surfaces a `.failed` state
    /// instead of crashing the app.
    static func live() -> FailureLogStore {
        FailureLogStore { owner, repo, jobId in
            let c = try GHClient()
            return try await c.fetchJobLog(owner: owner, repo: repo, jobId: jobId)
        }
    }

    func status(for pr: InboxPR, check: CheckSummary) -> LoadStatus {
        guard let jobId = CIFailureLogTail.parseJobId(from: check.url) else {
            return .failed("No job log available for this check.")
        }
        return statuses[key(prNodeId: pr.nodeId, headSha: pr.headSha, jobId: jobId)] ?? .idle
    }

    /// Fire a fetch for a single failed check. Idempotent — concurrent
    /// calls collapse, completed entries are left alone (call `invalidate`
    /// to force a refresh).
    func ensureLoaded(for pr: InboxPR, check: CheckSummary) {
        guard let jobId = CIFailureLogTail.parseJobId(from: check.url) else { return }
        let k = key(prNodeId: pr.nodeId, headSha: pr.headSha, jobId: jobId)
        if let existing = statuses[k] {
            switch existing {
            case .loading, .loaded: return
            case .idle, .failed:    break   // allow retry on .failed
            }
        }
        statuses[k] = .loading
        let owner = pr.owner, repo = pr.repo
        Task { [weak self, fetcher = logFetcher] in
            do {
                let raw = try await fetcher(owner, repo, jobId)
                let tail = CIFailureLogTail.tail(raw)
                await MainActor.run { self?.statuses[k] = .loaded(tail) }
            } catch {
                await MainActor.run {
                    self?.statuses[k] = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Force a refresh for one check — used by the inline "Reload"
    /// affordance and by ReviewQueueWorker on Re-run.
    func invalidate(for pr: InboxPR, check: CheckSummary) {
        guard let jobId = CIFailureLogTail.parseJobId(from: check.url) else { return }
        statuses[key(prNodeId: pr.nodeId, headSha: pr.headSha, jobId: jobId)] = .idle
    }

    /// Test/preview only: pre-populate so screenshots can render the
    /// expanded-log state deterministically.
    func _setLoadedForScreenshot(pr: InboxPR, check: CheckSummary, tail: String) {
        guard let jobId = CIFailureLogTail.parseJobId(from: check.url) else { return }
        statuses[key(prNodeId: pr.nodeId, headSha: pr.headSha, jobId: jobId)] = .loaded(tail)
    }

    /// Best-effort fetch of every parseable failed-check log on a PR.
    /// Returns once all in-flight fetches settle. Used by
    /// `ReviewQueueWorker` to seed the prompt's `## CI failures`
    /// section before assembly.
    func fetchAllFailures(for pr: InboxPR) async -> [CIFailureLog] {
        let failed = pr.allCheckSummaries.filter { $0.bucket == .failed }
        var out: [CIFailureLog] = []
        await withTaskGroup(of: CIFailureLog?.self) { group in
            for check in failed {
                guard let jobId = CIFailureLogTail.parseJobId(from: check.url) else { continue }
                let owner = pr.owner, repo = pr.repo
                let name = check.name
                let fetcher = logFetcher
                group.addTask {
                    do {
                        let raw = try await fetcher(owner, repo, jobId)
                        return CIFailureLog(jobName: name, logTail: CIFailureLogTail.tail(raw))
                    } catch {
                        return nil
                    }
                }
            }
            for await item in group {
                if let item { out.append(item) }
            }
        }
        // Cache the tails so the UI doesn't need to re-fetch when the
        // user expands the same failure.
        for item in out {
            if let check = pr.allCheckSummaries.first(where: { $0.name == item.jobName }) {
                _setLoadedForScreenshot(pr: pr, check: check, tail: item.logTail)
            }
        }
        return out
    }

    private func key(prNodeId: String, headSha: String, jobId: Int64) -> String {
        "\(prNodeId)@\(headSha)#\(jobId)"
    }
}
