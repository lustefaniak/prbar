import Foundation
import SwiftData

/// Read-only access to state the SwiftData store held before it moved to
/// files. Used as the fallback of a `JSONStateFile` until its first save,
/// so a completed review isn't re-run (and re-billed) just because its
/// storage changed. Nothing here writes to or deletes from the old store.
enum LegacyStateMigration {
    static func reviewStates(_ container: ModelContainer) -> [String: ReviewState]? {
        let context = ModelContext(container)
        guard let rows = try? context.fetch(FetchDescriptor<ReviewStateEntry>()), !rows.isEmpty else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var result: [String: ReviewState] = [:]
        for row in rows {
            if let state = try? decoder.decode(ReviewState.self, from: row.payload) {
                result[row.prNodeId] = state
            }
        }
        return result
    }

    static func inboxSnapshot(_ container: ModelContainer) -> [InboxPR]? {
        let context = ModelContext(container)
        guard let rows = try? context.fetch(FetchDescriptor<InboxSnapshotEntry>()), !rows.isEmpty else {
            return nil
        }
        let decoder = JSONDecoder()
        return rows.compactMap { try? decoder.decode(InboxPR.self, from: $0.payload) }
    }
}
