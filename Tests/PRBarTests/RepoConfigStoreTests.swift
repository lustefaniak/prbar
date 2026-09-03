import XCTest
import SwiftData
@testable import PRBar

@MainActor
final class RepoConfigStoreTests: XCTestCase {

    func testUpsertPersistsAcrossInstances() {
        let container = PRBarModelContainer.inMemory()
        let store1 = RepoConfigStore(container: container)
        var cfg = RepoConfig.default
        cfg.repoGlobs = ["acme/infra"]
        store1.upsert(cfg)
        XCTAssertEqual(store1.userConfigs.count, 1)

        let store2 = RepoConfigStore(container: container)
        XCTAssertEqual(store2.userConfigs.count, 1)
        XCTAssertEqual(store2.userConfigs.first?.repoGlobs, ["acme/infra"])
    }

    func testRemoveDropsRow() {
        let container = PRBarModelContainer.inMemory()
        let store = RepoConfigStore(container: container)
        var cfg = RepoConfig.default
        cfg.repoGlobs = ["acme/x"]
        store.upsert(cfg)
        store.remove(id: cfg.id)

        let reloaded = RepoConfigStore(container: container)
        XCTAssertEqual(reloaded.userConfigs.count, 0)
    }

    func testEditRepoGlobsKeepsRowIdentity() throws {
        let container = PRBarModelContainer.inMemory()
        let store = RepoConfigStore(container: container)
        var cfg = RepoConfig.default
        cfg.repoGlobs = ["acme/x"]
        store.upsert(cfg)

        let context = ModelContext(container)
        let descriptor = FetchDescriptor<RepoConfigEntry>()
        let before = try context.fetch(descriptor).first!.persistentModelID

        // Rename the glob — id stays the same, so we should hit the
        // same SwiftData row, not insert a new one.
        var renamed = cfg
        renamed.repoGlobs = ["acme/y"]
        store.upsert(renamed)

        let context2 = ModelContext(container)
        let after = try context2.fetch(descriptor)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.persistentModelID, before)

        let reloaded = RepoConfigStore(container: container)
        XCTAssertEqual(reloaded.userConfigs.first?.repoGlobs, ["acme/y"])
    }

    func testIncrementalSavePreservesRowIdentity() throws {
        let container = PRBarModelContainer.inMemory()
        let store = RepoConfigStore(container: container)
        var a = RepoConfig.default; a.repoGlobs = ["acme/a"]
        var b = RepoConfig.default; b.repoGlobs = ["acme/b"]
        store.setAll([a, b])

        // Capture row identities (SwiftData PersistentIdentifier) before
        // an unrelated edit to row #1.
        let context = ModelContext(container)
        let descriptor1 = FetchDescriptor<RepoConfigEntry>(
            sortBy: [SortDescriptor(\RepoConfigEntry.orderIndex)]
        )
        let before = try context.fetch(descriptor1)
        let idsBefore = before.map(\.persistentModelID)
        XCTAssertEqual(before.count, 2)

        // Edit only row #1.
        var bEdited = b; bEdited.rootPatterns = ["kernel-*"]
        store.setAll([a, bEdited])

        let context2 = ModelContext(container)
        let after = try context2.fetch(descriptor1)
        let idsAfter = after.map(\.persistentModelID)
        XCTAssertEqual(idsBefore, idsAfter,
            "Incremental save must not churn SwiftData row identity — old impl deleted-and-recreated, which would change ids")

        // And the edit landed.
        let reloaded = RepoConfigStore(container: container)
        XCTAssertEqual(reloaded.userConfigs.last?.rootPatterns, ["kernel-*"])
    }

    func testReorderPreservesRowIdentityAndPersists() throws {
        let container = PRBarModelContainer.inMemory()
        let store = RepoConfigStore(container: container)
        var a = RepoConfig.default; a.repoGlobs = ["acme/a"]
        var b = RepoConfig.default; b.repoGlobs = ["acme/b"]
        var c = RepoConfig.default; c.repoGlobs = ["acme/c"]
        store.setAll([a, b, c])

        let ctx = ModelContext(container)
        let descriptor = FetchDescriptor<RepoConfigEntry>(
            sortBy: [SortDescriptor(\RepoConfigEntry.orderIndex)]
        )
        let before = try ctx.fetch(descriptor).map(\.persistentModelID)
        XCTAssertEqual(before.count, 3)

        // Drag c to the front.
        store.setAll([c, a, b])

        // Same SwiftData rows, just different orderIndex — stable
        // identity is the whole point of matching by config.id.
        let ctx2 = ModelContext(container)
        let after = try ctx2.fetch(descriptor)
        XCTAssertEqual(Set(after.map(\.persistentModelID)), Set(before))

        let reloaded = RepoConfigStore(container: container)
        XCTAssertEqual(reloaded.userConfigs.map(\.repoGlobs),
                       [["acme/c"], ["acme/a"], ["acme/b"]])
    }

    func testSetAllPreservesOrder() {
        let container = PRBarModelContainer.inMemory()
        let store = RepoConfigStore(container: container)
        var a = RepoConfig.default; a.repoGlobs = ["acme/a"]
        var b = RepoConfig.default; b.repoGlobs = ["acme/b"]
        var c = RepoConfig.default; c.repoGlobs = ["acme/c"]
        store.setAll([c, a, b])

        let reloaded = RepoConfigStore(container: container)
        XCTAssertEqual(reloaded.userConfigs.map(\.repoGlobs), [["acme/c"], ["acme/a"], ["acme/b"]])
    }

    // MARK: - review defaults

    /// A suite of its own so these never touch the real app's settings.
    private func isolatedDefaults() -> UserDefaults {
        let suite = "prbar.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    func testReviewDefaultsPersistAcrossInstances() {
        let container = PRBarModelContainer.inMemory()
        let userDefaults = isolatedDefaults()

        let store = RepoConfigStore(container: container, userDefaults: userDefaults)
        store.defaults.maxCostUsdPerSubreview = 8.0
        store.defaults.toolMode = .minimal

        let reloaded = RepoConfigStore(container: container, userDefaults: userDefaults)
        XCTAssertEqual(reloaded.defaults.maxCostUsdPerSubreview, 8.0)
        XCTAssertEqual(reloaded.defaults.toolMode, .minimal)
    }

    func testResolveFoldsDefaultsIntoTheMatchingRule() {
        let store = RepoConfigStore(container: PRBarModelContainer.inMemory(), userDefaults: isolatedDefaults())
        store.defaults.maxCostUsdPerSubreview = 6.0
        store.defaults.reviewTimeoutSeconds = 1200

        var rule = RepoConfig.default
        rule.repoGlobs = ["acme/infra"]
        rule.reviewTimeoutSeconds = 120
        store.upsert(rule)

        let matched = store.resolve(owner: "acme", repo: "infra")
        XCTAssertEqual(matched.reviewTimeoutSeconds, 120, "rule overrides")
        XCTAssertEqual(matched.maxCostUsdPerSubreview, 6.0, "rest inherits")

        let unmatched = store.resolve(owner: "other", repo: "thing")
        XCTAssertEqual(unmatched.reviewTimeoutSeconds, 1200)
        XCTAssertEqual(unmatched.maxCostUsdPerSubreview, 6.0)
    }

    func testEditingDefaultsFiresOnChange() {
        let store = RepoConfigStore(container: PRBarModelContainer.inMemory(), userDefaults: isolatedDefaults())
        var fired = 0
        store.onChange = { fired += 1 }

        store.defaults.maxCostUsdPerSubreview = 2.0
        XCTAssertEqual(fired, 1)

        // Re-assigning the same value shouldn't churn the resolvers or
        // trigger a re-poll — SwiftUI writes bindings back on every edit.
        store.defaults.maxCostUsdPerSubreview = 2.0
        XCTAssertEqual(fired, 1)
    }

    /// The resolver is a snapshot: a stale one must not observe later
    /// edits, and `onChange` is what hands out a fresh one.
    func testMakeResolverSnapshotsDefaults() {
        let store = RepoConfigStore(container: PRBarModelContainer.inMemory(), userDefaults: isolatedDefaults())
        store.defaults.maxCostUsdPerSubreview = 1.0
        let resolver = store.makeResolver()

        store.defaults.maxCostUsdPerSubreview = 9.0

        XCTAssertEqual(resolver("acme", "x").maxCostUsdPerSubreview, 1.0)
        XCTAssertEqual(store.makeResolver()("acme", "x").maxCostUsdPerSubreview, 9.0)
    }
}
