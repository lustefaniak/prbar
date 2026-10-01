import Foundation
import SwiftData

/// One-time copy of the action and review history from the SwiftData store
/// into `history/`, the first time a build with file-based history runs.
///
/// Guarded by a marker file rather than by "the directory is empty": the
/// user can clear history, and that must not bring the old rows back. The
/// SwiftData rows are left in place, so an older build still shows them.
enum LegacyHistoryMigration {
    static let markerName = ".migrated-from-swiftdata"

    @MainActor
    static func migrateIfNeeded(
        historyDirectory: URL,
        container: @autoclosure () -> ModelContainer = PRBarModelContainer.live()
    ) {
        let marker = historyDirectory.appendingPathComponent(markerName)
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        let context = ModelContext(container())

        let actions = (try? context.fetch(FetchDescriptor<ActionLogEntry>())) ?? []
        let reviews = (try? context.fetch(FetchDescriptor<ReviewLogEntry>())) ?? []
        do {
            try ActionHistory.actions(in: historyDirectory).appendAll(actions.map(record(from:)))
            let reviewHistory = ReviewHistory(in: historyDirectory)
            var records: [ReviewRecord] = []
            for entry in reviews {
                var record = record(from: entry)
                if entry.status == .completed, entry.payloadVersion <= 1, let payload = entry.payload {
                    try reviewHistory.writeFull(payload, id: record.id)
                    record.hasReview = true
                }
                records.append(record)
            }
            try reviewHistory.index.appendAll(records)
            try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
            try Data().write(to: marker)
            PRBarLog.lifecycle.notice("migrated history: \(actions.count, privacy: .public) actions, \(reviews.count, privacy: .public) reviews")
        } catch {
            // No marker, so the next launch tries again. Rows already
            // appended would then be appended twice; acceptable for a
            // failure that also means the disk is refusing writes.
            PRBarLog.lifecycle.error("history migration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func record(from entry: ActionLogEntry) -> ActionRecord {
        ActionRecord(
            id: entry.id, timestamp: entry.timestamp, kind: entry.kind, outcome: entry.outcome,
            errorMessage: entry.errorMessage, prNodeId: entry.prNodeId, owner: entry.owner,
            repo: entry.repo, prNumber: entry.prNumber, prTitle: entry.prTitle,
            headSha: entry.headSha, detail: entry.detail, costUsd: entry.costUsd
        )
    }

    static func record(from entry: ReviewLogEntry) -> ReviewRecord {
        ReviewRecord(
            id: entry.id, prNodeId: entry.prNodeId, owner: entry.owner, repo: entry.repo,
            prNumber: entry.prNumber, prTitle: entry.prTitle, headSha: entry.headSha,
            providerId: entry.providerId, triggeredAt: entry.triggeredAt,
            completedAt: entry.completedAt, status: entry.status, verdict: entry.verdict,
            costUsd: entry.costUsd, errorMessage: entry.errorMessage
        )
    }
}
