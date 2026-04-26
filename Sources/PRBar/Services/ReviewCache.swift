import Foundation
import SwiftData

/// SwiftData-backed persistence for `ReviewState` so AI verdicts survive
/// a relaunch. Keyed by `prNodeId`; the queue worker keeps the latest
/// review per PR. The stored review's `headSha` lets the worker detect
/// staleness when the PR's head moves on the next poll — at that point
/// the cached verdict is shown as "outdated for SHA xyz" and the PR is
/// re-enqueued for a fresh triage.
///
/// The `ReviewState` graph is JSON-encoded into the entry's `payload`
/// field — modeling the full `AggregatedReview` / `PriorReview` /
/// nested annotation tree as relational `@Model`s buys nothing here
/// (no relational queries against review internals) and would cost
/// migration risk every time those structs evolve.
struct ReviewCache: Sendable {
    let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    /// Convenience for production paths.
    static func live() -> ReviewCache {
        ReviewCache(container: PRBarModelContainer.live())
    }

    /// Read every persisted review state. Best-effort decode: any entry
    /// whose payload fails to decode (e.g. after a `ReviewState` schema
    /// change) is dropped rather than crashing the launch.
    func load() -> [String: ReviewState] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<ReviewStateEntry>()
        guard let entries = try? context.fetch(descriptor) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var result: [String: ReviewState] = [:]
        for entry in entries {
            guard let state = try? decoder.decode(ReviewState.self, from: entry.payload) else {
                continue
            }
            result[entry.prNodeId] = state
        }
        return result
    }

    /// Replace the persisted set with `states`. Any rows for PRs no longer
    /// in the dictionary are deleted (the worker discards `ReviewState`
    /// once the PR leaves the inbox, so we mirror that here).
    func save(_ states: [String: ReviewState]) {
        let context = ModelContext(container)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let descriptor = FetchDescriptor<ReviewStateEntry>()
        let existing = (try? context.fetch(descriptor)) ?? []
        let existingByKey = Dictionary(uniqueKeysWithValues: existing.map { ($0.prNodeId, $0) })

        for (key, state) in states {
            guard let payload = try? encoder.encode(state) else { continue }
            if let row = existingByKey[key] {
                row.payload = payload
                row.triggeredAt = state.triggeredAt
            } else {
                context.insert(ReviewStateEntry(
                    prNodeId: key, payload: payload, triggeredAt: state.triggeredAt
                ))
            }
        }
        // Drop rows whose PRs are no longer tracked.
        for (key, row) in existingByKey where states[key] == nil {
            context.delete(row)
        }
        try? context.save()
    }
}
