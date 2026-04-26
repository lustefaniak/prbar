import Foundation

/// Persists the most recent inbox snapshot to disk so the popover shows
/// known state immediately on launch instead of "Fetching…" until the
/// first poll lands.
///
/// Phase 1f deliberately uses a JSON file rather than SwiftData. Phase 2+
/// will add ReviewRun + ActionLog which actually want relational queries —
/// at that point we'll introduce SwiftData and migrate this single
/// snapshot into it.
actor SnapshotCache {
    private let fileURL: URL

    static let defaultDirectory: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("io.synq.prbar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init(directory: URL = SnapshotCache.defaultDirectory) {
        self.fileURL = directory.appendingPathComponent("inbox-snapshot.json")
    }

    func load() -> [InboxPR] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([InboxPR].self, from: data)) ?? []
    }

    func save(_ prs: [InboxPR]) {
        do {
            let data = try JSONEncoder().encode(prs)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("SnapshotCache.save failed: %@", String(describing: error))
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
