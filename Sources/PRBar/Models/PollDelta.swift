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
