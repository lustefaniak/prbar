import Foundation
import SwiftData

/// Shared SwiftData store for PRBar. Phase 2+ ports the JSON snapshot /
/// repo-config / review / diff / failure-log files into this container
/// one model at a time. ActionLog is the first inhabitant.
///
/// Production store lives at
/// `~/Library/Application Support/io.synq.prbar/store.sqlite`. Tests use
/// `inMemory()` so each XCTest gets a fresh, isolated container.
enum PRBarModelContainer {
    /// All `@Model` types persisted in the shared store. Adding a new
    /// model means appending it here so the container's schema migrates
    /// to include the new entity on next launch.
    static let schema: Schema = Schema([
        ActionLogEntry.self,
        ReviewStateEntry.self,
        ReviewLogEntry.self,
        RepoConfigEntry.self,
        InboxSnapshotEntry.self,
        DiffCacheEntry.self,
        FailureLogCacheEntry.self,
    ])

    /// `~/Library/Application Support/io.synq.prbar/`.
    static let appSupportDirectory: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = base.appendingPathComponent("io.synq.prbar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func live() -> ModelContainer {
        let url = appSupportDirectory.appendingPathComponent("store.sqlite")
        do {
            let config = ModelConfiguration(url: url)
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Falling back to in-memory keeps the app launchable rather
            // than crashing on a corrupt store. The user loses history
            // on restart, which is preferable to a stuck launch.
            NSLog("PRBarModelContainer.live failed (%@), falling back to in-memory", String(describing: error))
            return inMemory()
        }
    }

    static func inMemory() -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        // swiftlint:disable:next force_try
        return try! ModelContainer(for: schema, configurations: [config])
    }
}
