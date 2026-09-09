import Foundation
import SwiftData

/// Age-based eviction for the SwiftData logs and caches.
///
/// Nothing bounded them before, so a long-lived install accumulated every
/// review, diff and action it had ever seen. Each limit is set by what the
/// UI can actually reach: History renders the last 200 review rows and spend
/// queries span the current day, while both caches are keyed by a head SHA,
/// so a row's value expires the moment the PR is pushed to again.
///
/// `ReviewStateEntry` is absent deliberately — it mirrors the live inbox and
/// is pruned per poll by `ReviewQueueWorker`, not by age.
enum StoreRetention {
    static let reviewLog: TimeInterval = days(90)
    static let actionLog: TimeInterval = days(180)
    static let failureLogCache: TimeInterval = days(30)
    static let diffCache: TimeInterval = days(14)

    static func days(_ count: Double) -> TimeInterval { count * 24 * 60 * 60 }

    /// Delete every row past its type's limit. Best-effort: failing here
    /// costs disk space, never correctness, so nothing propagates.
    ///
    /// Written out per model rather than generically because `#Predicate`
    /// needs a concrete type — a keypath-driven helper won't compile.
    static func sweep(_ container: ModelContainer, now: Date = Date()) {
        let context = ModelContext(container)

        let reviewCutoff = now.addingTimeInterval(-reviewLog)
        try? context.delete(
            model: ReviewLogEntry.self,
            where: #Predicate { $0.triggeredAt < reviewCutoff }
        )
        let actionCutoff = now.addingTimeInterval(-actionLog)
        try? context.delete(
            model: ActionLogEntry.self,
            where: #Predicate { $0.timestamp < actionCutoff }
        )
        let failureCutoff = now.addingTimeInterval(-failureLogCache)
        try? context.delete(
            model: FailureLogCacheEntry.self,
            where: #Predicate { $0.savedAt < failureCutoff }
        )
        let diffCutoff = now.addingTimeInterval(-diffCache)
        try? context.delete(
            model: DiffCacheEntry.self,
            where: #Predicate { $0.savedAt < diffCutoff }
        )
        try? context.save()
    }
}
