import Foundation

/// One poll's worth of inbox change, diffed against the previous
/// snapshot. Consumed by `EventDeriver` to decide which notifications
/// a poll earned.
struct PollDelta: Sendable, Hashable {
    let added: [InboxPR]
    let removed: [InboxPR]
    let changed: [InboxPR]   // new state of PRs whose previous snapshot differed

    var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && changed.isEmpty
    }

    static let empty = PollDelta(added: [], removed: [], changed: [])
}


/// Whether a repo's `excludeTitlePatterns` reject this PR's title.
///
/// Lives here rather than inside `PRPoller` because the poller is not the
/// only entry point any more: the headless CLI is handed a PR directly and
/// never polls, so a rule enforced only on the poll path silently does not
/// apply to it. Case-insensitive fnmatch, with `!pattern` negation handled
/// by `GlobMatcher`.
enum TitleExclusion {
    static func isExcluded(title: String, patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return false }
        return GlobMatcher.anyMatch(patterns.map { $0.lowercased() }, title.lowercased())
    }
}
