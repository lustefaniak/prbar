import Foundation
import Observation

/// Every AI triage that reached a terminal state, newest first: the
/// Review History tab and the daily cost cap read it. Backed by
/// `history/reviews/` in the state directory (shared with the CLI): an
/// index of `ReviewRecord`s in monthly JSONL files, plus one file per
/// completed review, loaded when a row is opened.
@MainActor
@Observable
final class ReviewLogStore {
    private(set) var entries: [ReviewRecord]

    @ObservationIgnored
    let history: ReviewHistory

    @ObservationIgnored
    private var reviewCache: [UUID: AggregatedReview] = [:]

    init(history: ReviewHistory) {
        self.history = history
        self.entries = history.readAll().sorted { $0.triggeredAt > $1.triggeredAt }
    }

    static func live(historyDirectory: URL = HistoryLocation.directory()) -> ReviewLogStore {
        return ReviewLogStore(history: ReviewHistory(in: historyDirectory))
    }

    static func temporary() -> ReviewLogStore {
        ReviewLogStore(history: ReviewHistory(in: FileManager.default.temporaryDirectory
            .appendingPathComponent("prbar-history-\(UUID().uuidString)")))
    }

    /// Append a completed-review row. Write failures are logged, not
    /// thrown — losing one history row should never block the review.
    func recordCompleted(
        pr: InboxPR,
        headSha: String,
        providerId: ProviderID,
        triggeredAt: Date,
        completedAt: Date = Date(),
        review: AggregatedReview
    ) {
        var record = ReviewRecord(
            prNodeId: pr.nodeId, owner: pr.owner, repo: pr.repo,
            prNumber: pr.number, prTitle: pr.title, headSha: headSha,
            providerId: providerId, triggeredAt: triggeredAt, completedAt: completedAt,
            status: .completed, verdict: review.verdict, costUsd: review.costUsd
        )
        do {
            try history.append(record, review: review)
            record.hasReview = true
            reviewCache[record.id] = review.strippingRawStreams()
        } catch {
            PRBarLog.triage.error("review log write failed: \(error.localizedDescription, privacy: .public)")
        }
        insert(record)
    }

    /// Append a failed-run row. `costUsd` is whatever the provider
    /// surfaced before failing — may be nil (codex always, claude when
    /// killed before the terminal `result` event, cap-blocked at
    /// enqueue with no spend incurred).
    func recordFailed(
        pr: InboxPR,
        headSha: String,
        providerId: ProviderID,
        triggeredAt: Date,
        completedAt: Date = Date(),
        errorMessage: String,
        costUsd: Double? = nil
    ) {
        let record = ReviewRecord(
            prNodeId: pr.nodeId, owner: pr.owner, repo: pr.repo,
            prNumber: pr.number, prTitle: pr.title, headSha: headSha,
            providerId: providerId, triggeredAt: triggeredAt, completedAt: completedAt,
            status: .failed, costUsd: costUsd, errorMessage: errorMessage
        )
        do {
            try history.append(record, review: nil)
        } catch {
            PRBarLog.triage.error("review log write failed: \(error.localizedDescription, privacy: .public)")
        }
        insert(record)
    }

    private func insert(_ record: ReviewRecord) {
        let at = entries.firstIndex { $0.triggeredAt <= record.triggeredAt } ?? entries.endIndex
        entries.insert(record, at: at)
    }

    /// The stored review for a row, or nil for failed runs and rows whose
    /// file is missing.
    func review(for id: UUID) -> AggregatedReview? {
        if let cached = reviewCache[id] { return cached }
        guard let loaded = history.review(id: id) else { return nil }
        reviewCache[id] = loaded
        return loaded
    }

    /// Sum of `costUsd` across rows whose `triggeredAt >= since`. Nil
    /// costs (codex / killed mid-stream) contribute zero — they aren't
    /// known spend, so we don't double-count by guessing.
    func spend(since: Date) -> Double {
        entries.reduce(0) { $1.triggeredAt >= since ? $0 + ($1.costUsd ?? 0) : $0 }
    }

    /// Local-calendar start of "today" — the daily-cap window boundary.
    /// Local rather than UTC so a user who reviews PRs on their normal
    /// work day sees a single window, not one that resets at 8pm /
    /// 4am depending on timezone offset. Captured here (not at the call
    /// site) so the rule is testable.
    static func startOfDay(_ now: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: now)
    }

    func todaysSpend(calendar: Calendar = .current) -> Double {
        spend(since: Self.startOfDay(calendar: calendar))
    }

    /// Re-read the files, e.g. after the background history migration.
    func reload() {
        entries = history.readAll().sorted { $0.triggeredAt > $1.triggeredAt }
    }

    func fetchAll(limit: Int? = nil) -> [ReviewRecord] {
        guard let limit else { return entries }
        return Array(entries.prefix(limit))
    }

    /// Wipe every row. Wired to the History view's "Clear" button
    /// (confirmation in the UI).
    func clearAll() {
        history.clear()
        entries = []
        reviewCache = [:]
    }

    func prune(before cutoff: Date) {
        history.prune(before: cutoff)
        entries.removeAll { $0.triggeredAt < cutoff }
    }
}
