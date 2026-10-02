import XCTest
import SwiftData
@testable import PRBar

/// Runs every legacy migration against the developer's real SwiftData
/// store, opened read-only, into a temporary directory, and prints what
/// came across. Gated by `touch /tmp/prbar-live-migration` because it reads
/// real data (and can take seconds on a large store); `bin/test` skips it.
@MainActor
final class LiveMigrationSmokeTests: XCTestCase {
    func testMigrateRealStoreReadOnly() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "/tmp/prbar-live-migration"),
                          "touch /tmp/prbar-live-migration to run")
        let storeURL = PRBarModelContainer.appSupportDirectory.appendingPathComponent("store.sqlite")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: storeURL.path), "no legacy store")
        let container = try ModelContainer(
            for: PRBarModelContainer.schema,
            configurations: [ModelConfiguration(url: storeURL, allowsSave: false)]
        )
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("prbar-live-migration-\(UUID().uuidString)")
        print("live-migration: output in \(out.path)")

        var t = Date()
        let config = try XCTUnwrap(LegacyConfigMigration.read(container: container, userDefaults: .standard))
        let yaml = try ConfigFile.encode(config)
        try ConfigFile.write(yaml, to: out.appendingPathComponent("prbar.yaml"))
        let reloaded = try ConfigFile.decode(yaml)
        XCTAssertEqual(reloaded.warnings, [])
        XCTAssertEqual(reloaded.config.defaults, config.defaults)
        print("live-migration: config repos=\(config.legacyRepos.count) provider=\(config.defaultProvider) in \(Date().timeIntervalSince(t))s")

        t = Date()
        let history = out.appendingPathComponent("history")
        LegacyHistoryMigration.migrateIfNeeded(historyDirectory: history, container: container)
        let actions = ActionLogStore(history: .actions(in: history))
        let reviews = ReviewLogStore(history: ReviewHistory(in: history))
        let legacyActions = try ModelContext(container).fetchCount(FetchDescriptor<ActionLogEntry>())
        let legacyReviews = try ModelContext(container).fetchCount(FetchDescriptor<ReviewLogEntry>())
        XCTAssertEqual(actions.entries.count, legacyActions)
        XCTAssertEqual(reviews.entries.count, legacyReviews)
        let withReview = reviews.entries.filter(\.hasReview)
        XCTAssertEqual(withReview.prefix(20).filter { reviews.review(for: $0.id) == nil }.count, 0,
                       "every stored review decodes")
        print("live-migration: history actions=\(actions.entries.count) reviews=\(reviews.entries.count) (\(withReview.count) with payload) in \(Date().timeIntervalSince(t))s")

        t = Date()
        let states = LegacyStateMigration.reviewStates(container) ?? [:]
        let inbox = LegacyStateMigration.inboxSnapshot(container) ?? []
        ReviewStateFile(stateDirectory: out).save(states)
        XCTAssertEqual(ReviewStateFile(stateDirectory: out).load().count, states.count)
        print("live-migration: review states=\(states.count) inbox=\(inbox.count) in \(Date().timeIntervalSince(t))s")
    }
}
