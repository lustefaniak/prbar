import Foundation
import Observation

/// On-demand cache of failed Actions job logs. Mirrors `DiffStore`'s
/// shape so `PRDetailView` can show inline expandable failure logs
/// without round-tripping through GitHub on every disclosure toggle.
/// Keyed by `(prNodeId, headSha, jobId)` so a force-push or job re-run
/// (which mints a fresh jobId) auto-invalidates the cache.
///
/// Hits hydrate from `~/.cache/prbar/ci-logs` on first lookup; only `.loaded` results
/// are persisted (transient `.loading` / `.failed` stay in memory).
@MainActor
@Observable
final class FailureLogStore {
    enum LoadStatus: Sendable, Hashable, Codable {
        case idle
        case loading
        case loaded(String)        // tailed log, timestamps stripped
        case failed(String)
    }

    private(set) var statuses: [String: LoadStatus] = [:]

    @ObservationIgnored
    var logFetcher: @Sendable (_ owner: String, _ repo: String, _ jobId: Int64) async throws -> String

    @ObservationIgnored
    private let cache: FileCache?

    init(
        logFetcher: @escaping @Sendable (_ owner: String, _ repo: String, _ jobId: Int64) async throws -> String,
        cache: FileCache? = nil
    ) {
        self.logFetcher = logFetcher
        self.cache = cache
    }

    func status(for pr: InboxPR, check: CheckSummary) -> LoadStatus {
        guard let jobId = CIFailureLogTail.parseJobId(from: check.url) else {
            return .failed("No job log available for this check.")
        }
        let k = Self.key(prNodeId: pr.nodeId, headSha: pr.headSha, jobId: jobId)
        if let s = statuses[k] { return s }
        if let tail = readPersisted(cacheKey: k) {
            statuses[k] = .loaded(tail)
            return .loaded(tail)
        }
        return .idle
    }

    /// Fire a fetch for a single failed check. Idempotent — concurrent
    /// calls collapse, completed entries are left alone (call `invalidate`
    /// to force a refresh).
    func ensureLoaded(for pr: InboxPR, check: CheckSummary) {
        guard let jobId = CIFailureLogTail.parseJobId(from: check.url) else { return }
        let k = Self.key(prNodeId: pr.nodeId, headSha: pr.headSha, jobId: jobId)
        if statuses[k] == nil, let tail = readPersisted(cacheKey: k) {
            statuses[k] = .loaded(tail)
            return
        }
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
                await MainActor.run {
                    self?.statuses[k] = .loaded(tail)
                    self?.writePersisted(cacheKey: k, tail: tail)
                }
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
        let k = Self.key(prNodeId: pr.nodeId, headSha: pr.headSha, jobId: jobId)
        statuses[k] = .idle
        deletePersisted(cacheKey: k)
    }

    /// Test/preview only: pre-populate so screenshots can render the
    /// expanded-log state deterministically.
    func _setLoadedForScreenshot(pr: InboxPR, check: CheckSummary, tail: String) {
        guard let jobId = CIFailureLogTail.parseJobId(from: check.url) else { return }
        statuses[Self.key(prNodeId: pr.nodeId, headSha: pr.headSha, jobId: jobId)] = .loaded(tail)
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
        // Cache the tails (in-memory + on-disk) so the UI doesn't need
        // to re-fetch when the user expands the same failure.
        for item in out {
            guard let check = pr.allCheckSummaries.first(where: { $0.name == item.jobName })
            else { continue }
            _setLoadedForScreenshot(pr: pr, check: check, tail: item.logTail)
            if let jobId = CIFailureLogTail.parseJobId(from: check.url) {
                let k = Self.key(prNodeId: pr.nodeId, headSha: pr.headSha, jobId: jobId)
                writePersisted(cacheKey: k, tail: item.logTail)
            }
        }
        return out
    }

    /// Shared with the front ends' mirror, which keys the same way.
    nonisolated static func key(prNodeId: String, headSha: String, jobId: Int64) -> String {
        "\(prNodeId)@\(headSha)#\(jobId)"
    }

    // MARK: - disk

    private func readPersisted(cacheKey: String) -> String? {
        cache?.read(cacheKey).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func writePersisted(cacheKey: String, tail: String) {
        cache?.write(cacheKey, Data(tail.utf8))
    }

    private func deletePersisted(cacheKey: String) {
        cache?.delete(cacheKey)
    }
}
