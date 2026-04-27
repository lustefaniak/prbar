import Foundation
import SwiftData

/// SwiftData-backed persistence for the most recent inbox snapshot, so
/// the popover shows known state immediately on launch instead of
/// "Fetching…" until the first poll lands.
///
/// One row per PR (`InboxSnapshotEntry`), keyed by `prNodeId`. The full
/// `InboxPR` struct is stored as a JSON blob — relational queries
/// against the inbox aren't a thing the app needs, and the alternative
/// (modeling every nested struct as a `@Model`) buys nothing while
/// costing migration risk every time the GraphQL response shape moves.
actor SnapshotCache {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    /// Convenience for production paths.
    static func live() -> SnapshotCache {
        SnapshotCache(container: PRBarModelContainer.live())
    }

    /// Read-only — each call creates its own `ModelContext` and never
    /// touches actor-isolated state, so it's safe to call synchronously
    /// from any thread (and crucially from the synchronous `live()`
    /// construction path, before the polling task starts).
    nonisolated func load() -> [InboxPR] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<InboxSnapshotEntry>()
        guard let rows = try? context.fetch(descriptor) else { return [] }
        let decoder = JSONDecoder()
        return rows.compactMap { try? decoder.decode(InboxPR.self, from: $0.payload) }
    }

    func save(_ prs: [InboxPR]) {
        let context = ModelContext(container)
        let encoder = JSONEncoder()
        let now = Date()

        let descriptor = FetchDescriptor<InboxSnapshotEntry>()
        let existing = (try? context.fetch(descriptor)) ?? []
        let existingByKey = Dictionary(uniqueKeysWithValues: existing.map { ($0.prNodeId, $0) })

        var keepKeys = Set<String>()
        for pr in prs {
            guard let payload = try? encoder.encode(pr) else { continue }
            keepKeys.insert(pr.nodeId)
            if let row = existingByKey[pr.nodeId] {
                row.payload = payload
                row.updatedAt = now
            } else {
                context.insert(InboxSnapshotEntry(
                    prNodeId: pr.nodeId, payload: payload, updatedAt: now
                ))
            }
        }
        for (key, row) in existingByKey where !keepKeys.contains(key) {
            context.delete(row)
        }
        try? context.save()
    }

    func clear() {
        let context = ModelContext(container)
        try? context.delete(model: InboxSnapshotEntry.self)
        try? context.save()
    }
}
