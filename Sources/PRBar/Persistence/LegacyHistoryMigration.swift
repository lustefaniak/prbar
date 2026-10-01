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

    /// Runs the copy on a background task and reports progress on the
    /// main actor. On a real store (~1,500 reviews, ~130 MB of payloads)
    /// it took minutes in a debug build, so the History views show it.
    /// `finished` gets nil on success, else the error; either way the
    /// stores should reload, since rows the app appended meanwhile and
    /// rows already copied are in the files.
    @MainActor
    static func migrateInBackground(
        historyDirectory: URL,
        storeURL: URL = PRBarModelContainer.appSupportDirectory.appendingPathComponent("store.sqlite"),
        progress: @escaping @MainActor @Sendable (HistoryImportProgress) -> Void,
        finished: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        guard needsMigration(historyDirectory) else { return }
        // A fresh install has no old store: mark it done without opening
        // (and so creating) one.
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            writeMarker(historyDirectory)
            return
        }
        Task.detached(priority: .utility) {
            let error = migrateIfNeeded(
                historyDirectory: historyDirectory,
                container: PRBarModelContainer.live(),
                progress: { p in Task { @MainActor in progress(p) } }
            )
            await MainActor.run { finished(error) }
        }
    }

    static func needsMigration(_ historyDirectory: URL) -> Bool {
        !FileManager.default.fileExists(atPath: historyDirectory.appendingPathComponent(markerName).path)
    }

    static let batchSize = 100

    /// Copies in batches so progress can be reported and only one batch of
    /// review payloads is in memory at a time. Rows already present in the
    /// files (by id) are skipped, so a retry after a failed or interrupted
    /// run doesn't duplicate them. Returns nil on success, else the error.
    @discardableResult
    static func migrateIfNeeded(
        historyDirectory: URL,
        container: ModelContainer,
        progress: @Sendable (HistoryImportProgress) -> Void = { _ in }
    ) -> String? {
        guard needsMigration(historyDirectory) else { return nil }
        let context = ModelContext(container)
        let actionTotal = (try? context.fetchCount(FetchDescriptor<ActionLogEntry>())) ?? 0
        let reviewTotal = (try? context.fetchCount(FetchDescriptor<ReviewLogEntry>())) ?? 0
        var report = HistoryImportProgress(done: 0, total: actionTotal + reviewTotal)
        progress(report)

        let actionLog = ActionHistory.actions(in: historyDirectory)
        let reviewHistory = ReviewHistory(in: historyDirectory)
        let haveActions = Set(actionLog.readAll().map(\.id))
        let haveReviews = Set(reviewHistory.readAll().map(\.id))
        do {
            var offset = 0
            while offset < actionTotal {
                var page = FetchDescriptor<ActionLogEntry>(sortBy: [SortDescriptor(\.timestamp)])
                page.fetchOffset = offset
                page.fetchLimit = batchSize * 5
                let rows = try context.fetch(page)
                if rows.isEmpty { break }
                try actionLog.appendAll(rows.map(record(from:)).filter { !haveActions.contains($0.id) })
                offset += rows.count
                report.done = offset
                progress(report)
            }

            offset = 0
            while offset < reviewTotal {
                // A fresh context per batch, so the payloads of the previous
                // batch can be released.
                let batchContext = ModelContext(container)
                var page = FetchDescriptor<ReviewLogEntry>(sortBy: [SortDescriptor(\.triggeredAt)])
                page.fetchOffset = offset
                page.fetchLimit = batchSize
                let rows = try batchContext.fetch(page)
                if rows.isEmpty { break }
                var records: [ReviewRecord] = []
                for entry in rows where !haveReviews.contains(entry.id) {
                    var record = record(from: entry)
                    if entry.status == .completed, entry.payloadVersion <= 1, let payload = entry.payload {
                        try reviewHistory.writeFull(payload, id: record.id)
                        record.hasReview = true
                    }
                    records.append(record)
                }
                try reviewHistory.index.appendAll(records)
                offset += rows.count
                report.done = actionTotal + offset
                progress(report)
            }
            writeMarker(historyDirectory)
            PRBarLog.lifecycle.notice("migrated history: \(actionTotal, privacy: .public) actions, \(reviewTotal, privacy: .public) reviews")
            return nil
        } catch {
            // No marker, so the next launch tries again and skips what was
            // already copied.
            PRBarLog.lifecycle.error("history migration failed: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
    }

    private static func writeMarker(_ historyDirectory: URL) {
        try? FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        try? Data().write(to: historyDirectory.appendingPathComponent(markerName))
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
