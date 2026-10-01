import Foundation

/// Age-based eviction for the history logs and the on-disk caches.
///
/// Each limit is set by what the UI can actually reach: History renders the
/// last 200 review rows and spend queries span the current day, while both
/// caches are keyed by a head SHA, so an entry's value expires the moment
/// the PR is pushed to again.
///
/// Review state is absent deliberately — it mirrors the live inbox and is
/// pruned per poll by `ReviewQueueWorker`, not by age.
enum StoreRetention {
    static let reviewLog: TimeInterval = days(90)
    static let actionLog: TimeInterval = days(180)
    /// Rule evaluations carry the full facts, PR bodies included; a month
    /// or two is what replaying an edit against recent PRs needs.
    static let ruleLog: TimeInterval = days(60)
    static let failureLogCache: TimeInterval = days(30)
    static let diffCache: TimeInterval = days(14)

    static func days(_ count: Double) -> TimeInterval { count * 24 * 60 * 60 }

    /// Best-effort: failing here costs disk space, never correctness.
    static func sweepCaches(in cacheDirectory: URL, now: Date = Date()) {
        FileCache(directory: cacheDirectory.appendingPathComponent("diffs"))
            .prune(olderThan: now.addingTimeInterval(-diffCache))
        FileCache(directory: cacheDirectory.appendingPathComponent("ci-logs"))
            .prune(olderThan: now.addingTimeInterval(-failureLogCache))
    }
}
