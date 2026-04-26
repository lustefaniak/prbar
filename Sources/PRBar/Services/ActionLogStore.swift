import Foundation
import Observation
import SwiftData

/// Thin `@MainActor @Observable` wrapper around the shared SwiftData
/// `ModelContext` for `ActionLogEntry`. Owns the write-side API used by
/// PRPoller / AutoApprovePolicy fire path; the read-side is direct
/// `@Query` from views.
///
/// Using a store wrapper (instead of plumbing `ModelContext` through
/// every service) keeps the concurrency story simple — all writes go
/// through the main actor, matching the rest of the UI layer's wiring.
@MainActor
@Observable
final class ActionLogStore {
    @ObservationIgnored
    let container: ModelContainer

    @ObservationIgnored
    private let context: ModelContext

    /// Bumps on every successful write so SwiftUI views observing this
    /// store re-render even when they aren't using `@Query` directly.
    private(set) var revision: Int = 0

    init(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    /// Convenience for production code paths that don't already have a
    /// container wired through.
    static func live() -> ActionLogStore {
        ActionLogStore(container: PRBarModelContainer.live())
    }

    /// Insert an action record. Logs (but doesn't throw) on save failures
    /// — losing a history row should never block the underlying action.
    func record(
        kind: ActionLogKind,
        outcome: ActionLogOutcome,
        pr: InboxPR,
        errorMessage: String? = nil,
        detail: String? = nil,
        headSha: String? = nil,
        costUsd: Double? = nil,
        timestamp: Date = Date()
    ) {
        let entry = ActionLogEntry(
            timestamp: timestamp,
            kind: kind,
            outcome: outcome,
            errorMessage: errorMessage,
            prNodeId: pr.nodeId,
            owner: pr.owner,
            repo: pr.repo,
            prNumber: pr.number,
            prTitle: pr.title,
            headSha: headSha ?? pr.headSha,
            detail: detail,
            costUsd: costUsd
        )
        context.insert(entry)
        do {
            try context.save()
            revision &+= 1
        } catch {
            NSLog("ActionLogStore.save failed: %@", String(describing: error))
        }
    }

    /// Read-side helper for non-`@Query` callers (e.g. tests).
    func fetchAll(limit: Int? = nil) -> [ActionLogEntry] {
        var descriptor = FetchDescriptor<ActionLogEntry>(
            sortBy: [SortDescriptor(\ActionLogEntry.timestamp, order: .reverse)]
        )
        if let limit { descriptor.fetchLimit = limit }
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Wipe all history. Exposed for a future Settings → "Clear history"
    /// button; also handy in tests.
    func clearAll() {
        try? context.delete(model: ActionLogEntry.self)
        try? context.save()
        revision &+= 1
    }
}
