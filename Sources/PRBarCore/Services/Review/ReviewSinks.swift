import Foundation

/// The four persistence seams `ReviewQueueWorker` writes through, declared
/// as protocols so the review pipeline compiles without SwiftData.
///
/// The macOS app conforms its SwiftData stores to these; the headless CLI
/// leaves every one of them nil — brahmanda's journal is the record there,
/// and its rolling budgets replace `cumulativeSpend`'s daily cap. Nil is a
/// supported configuration for all four, so nothing here needs a no-op
/// implementation.

/// Review state that survives a process exit. Nil disables persistence.
protocol ReviewStateCaching: Sendable {
    func load() -> [String: ReviewState]
    func save(_ states: [String: ReviewState])
}

/// Tails of failed CI jobs, fed into the prompt's `## CI failures` section.
protocol CIFailureTailing: Sendable {
    func fetchAllFailures(for pr: InboxPR) async -> [CIFailureLog]
}

/// History sink for posts the auto-review batch made. `AnyObject` because
/// the worker holds it weakly — the store outlives the worker.
@MainActor
protocol ActionLogging: AnyObject {
    func record(
        kind: ActionLogKind,
        outcome: ActionLogOutcome,
        pr: InboxPR,
        errorMessage: String?,
        detail: String?,
        headSha: String?,
        costUsd: Double?,
        timestamp: Date
    )
}

/// History sink for triage outcomes, and the spend ledger behind the
/// app's daily cost cap.
@MainActor
protocol ReviewLogging: AnyObject {
    func recordCompleted(
        pr: InboxPR,
        headSha: String,
        providerId: ProviderID,
        triggeredAt: Date,
        completedAt: Date,
        review: AggregatedReview
    )
    func recordFailed(
        pr: InboxPR,
        headSha: String,
        providerId: ProviderID,
        triggeredAt: Date,
        completedAt: Date,
        errorMessage: String,
        costUsd: Double?
    )
    func todaysSpend(calendar: Calendar) -> Double
}
