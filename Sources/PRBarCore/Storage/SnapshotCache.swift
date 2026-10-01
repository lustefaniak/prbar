import Foundation

/// The most recent inbox, so the popover shows known state on launch
/// instead of "Fetching…" until the first poll lands: `<state>/inbox.json`.
actor SnapshotCache {
    private let file: JSONStateFile<[InboxPR]>

    init(file: JSONStateFile<[InboxPR]>) {
        self.file = file
    }

    init(stateDirectory: URL, fallback: (@Sendable () -> [InboxPR]?)? = nil) {
        self.file = JSONStateFile(url: stateDirectory.appendingPathComponent("inbox.json"), fallback: fallback)
    }

    /// Synchronous so `PRPoller.loadCached()` can fill the list before the
    /// first poll starts; touches no actor state.
    nonisolated func load() -> [InboxPR] {
        file.load() ?? []
    }

    func save(_ prs: [InboxPR]) {
        file.save(prs)
    }

    func clear() {
        file.delete()
    }
}
