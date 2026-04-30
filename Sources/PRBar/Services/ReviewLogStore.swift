import Foundation
import Observation
import SwiftData

/// `@MainActor @Observable` write-side wrapper around the
/// `ReviewLogEntry` SwiftData table. Read-side is direct `@Query` from
/// views; this store exposes the few non-query helpers (append on
/// terminal triage, daily-window spend math, "clear all" admin action)
/// that don't fit a `@Query`.
///
/// Why a store at all (mirroring `ActionLogStore`'s pattern): SwiftData
/// `ModelContext` isn't `Sendable`; routing every write through a
/// `@MainActor` singleton keeps the concurrency story consistent with
/// the rest of the persistence layer and lets services hold a `weak`
/// ref without dragging in the container.
@MainActor
@Observable
final class ReviewLogStore {
    @ObservationIgnored
    let container: ModelContainer

    @ObservationIgnored
    private let context: ModelContext

    /// Bumps on every successful write so views observing the store
    /// itself (rather than a `@Query`) re-render. `@Query` already
    /// invalidates on its own.
    private(set) var revision: Int = 0

    init(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    static func live() -> ReviewLogStore {
        ReviewLogStore(container: PRBarModelContainer.live())
    }

    /// Append a completed-review row. Encoding failure is logged but
    /// not thrown — losing one history row should never block the
    /// underlying review pipeline.
    func recordCompleted(
        pr: InboxPR,
        headSha: String,
        providerId: ProviderID,
        triggeredAt: Date,
        completedAt: Date = Date(),
        review: AggregatedReview
    ) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try? encoder.encode(review)
        let entry = ReviewLogEntry(
            prNodeId: pr.nodeId,
            owner: pr.owner,
            repo: pr.repo,
            prNumber: pr.number,
            prTitle: pr.title,
            headSha: headSha,
            providerId: providerId,
            triggeredAt: triggeredAt,
            completedAt: completedAt,
            status: .completed,
            verdict: review.verdict,
            costUsd: review.costUsd,
            payload: payload
        )
        insert(entry)
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
        let entry = ReviewLogEntry(
            prNodeId: pr.nodeId,
            owner: pr.owner,
            repo: pr.repo,
            prNumber: pr.number,
            prTitle: pr.title,
            headSha: headSha,
            providerId: providerId,
            triggeredAt: triggeredAt,
            completedAt: completedAt,
            status: .failed,
            costUsd: costUsd,
            errorMessage: errorMessage
        )
        insert(entry)
    }

    private func insert(_ entry: ReviewLogEntry) {
        context.insert(entry)
        do {
            try context.save()
            revision &+= 1
        } catch {
            NSLog("ReviewLogStore.save failed: %@", String(describing: error))
        }
    }

    /// Sum of `costUsd` across rows whose `triggeredAt >= since`. Nil
    /// costs (codex / killed mid-stream) contribute zero — they aren't
    /// known spend, so we don't double-count by guessing.
    func spend(since: Date) -> Double {
        let predicate = #Predicate<ReviewLogEntry> { $0.triggeredAt >= since }
        let descriptor = FetchDescriptor<ReviewLogEntry>(predicate: predicate)
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.reduce(0) { $0 + ($1.costUsd ?? 0) }
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

    /// All rows, newest-first. Used by tests and the History view's
    /// non-`@Query` callers.
    func fetchAll(limit: Int? = nil) -> [ReviewLogEntry] {
        var descriptor = FetchDescriptor<ReviewLogEntry>(
            sortBy: [SortDescriptor(\ReviewLogEntry.triggeredAt, order: .reverse)]
        )
        if let limit { descriptor.fetchLimit = limit }
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Wipe every row. Wired to the History view's "Clear" button
    /// (confirmation in the UI). Also useful in tests.
    func clearAll() {
        try? context.delete(model: ReviewLogEntry.self)
        try? context.save()
        revision &+= 1
    }
}
