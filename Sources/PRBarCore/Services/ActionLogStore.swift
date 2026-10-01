import Foundation
import Observation

/// The History tab's data: every PR action PRBar took or tried, newest
/// first. Backed by `history/actions/*.jsonl` in the state directory
/// (shared with the CLI); the whole log is held in memory, since it is a
/// few hundred small rows and every view reads it whole.
@MainActor
@Observable
final class ActionLogStore {
    private(set) var entries: [ActionRecord]

    @ObservationIgnored
    let history: ActionHistory

    init(history: ActionHistory) {
        self.history = history
        self.entries = history.readAll().sorted { $0.timestamp > $1.timestamp }
    }

    /// The user's history directory. `LegacyHistoryMigration` fills it
    /// from the old SwiftData store once, in the background, then `reload`s.
    static func live(historyDirectory: URL = HistoryLocation.directory()) -> ActionLogStore {
        return ActionLogStore(history: .actions(in: historyDirectory))
    }

    /// A store over a fresh temporary directory, for tests and the XCTest host.
    static func temporary() -> ActionLogStore {
        ActionLogStore(history: .actions(in: FileManager.default.temporaryDirectory
            .appendingPathComponent("prbar-history-\(UUID().uuidString)")))
    }

    /// Append an action. Logs (but doesn't throw) on write failures —
    /// losing a history row should never block the underlying action.
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
        let record = ActionRecord(
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
        do {
            try history.append(record)
        } catch {
            PRBarLog.actions.error("action log write failed: \(error.localizedDescription, privacy: .public)")
        }
        let at = entries.firstIndex { $0.timestamp <= record.timestamp } ?? entries.endIndex
        entries.insert(record, at: at)
    }

    /// Re-read the files, e.g. after the background history migration.
    func reload() {
        entries = history.readAll().sorted { $0.timestamp > $1.timestamp }
    }

    func fetchAll(limit: Int? = nil) -> [ActionRecord] {
        guard let limit else { return entries }
        return Array(entries.prefix(limit))
    }

    func clearAll() {
        history.clear()
        entries = []
    }

    func prune(before cutoff: Date) {
        history.prune(before: cutoff)
        entries.removeAll { $0.timestamp < cutoff }
    }
}
