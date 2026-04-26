import Foundation

/// JSON-backed persistence for `ReviewState` so AI verdicts survive a
/// relaunch. Keyed by `prNodeId`; the in-memory dictionary keeps only
/// the latest review per PR. The stored review's `headSha` lets the
/// queue worker detect staleness when the PR's head moves on the next
/// poll — at that point the cached verdict is shown as "outdated for
/// SHA xyz" and the PR is re-enqueued for a fresh triage.
///
/// File: `~/Library/Application Support/io.synq.prbar/reviews.json`.
/// SwiftData migration is a follow-up; for now this is enough.
struct ReviewCache: Sendable {
    let fileURL: URL

    init(fileURL: URL = ReviewCache.defaultURL) {
        self.fileURL = fileURL
    }

    /// Read the persisted state. Empty dictionary on first run / corrupt
    /// file (we don't want to crash a launch on a bad cache).
    func load() -> [String: ReviewState] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: ReviewState].self, from: data)) ?? [:]
    }

    /// Atomically replace the persisted state. Failures are silent — the
    /// cache is best-effort, not load-bearing for correctness.
    func save(_ states: [String: ReviewState]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(states) else { return }
        // Ensure parent dir exists (matches SnapshotCache behavior).
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    static let defaultURL: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("io.synq.prbar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("reviews.json")
    }()
}
