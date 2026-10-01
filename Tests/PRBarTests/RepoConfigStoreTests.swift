import XCTest
import SwiftData
@testable import PRBar

@MainActor
final class RepoConfigStoreTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prbar-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private struct Paths {
        let file: URL
        let lastGood: URL
    }

    private func paths() throws -> Paths {
        let dir = try tempDir()
        return Paths(
            file: dir.appendingPathComponent("config/prbar.yaml"),
            lastGood: dir.appendingPathComponent("state/config.last-good.yaml")
        )
    }

    private func store(_ p: Paths, legacy: (@MainActor () -> PRBarConfig?)? = nil) -> RepoConfigStore {
        RepoConfigStore(fileURL: p.file, lastGoodURL: p.lastGood, legacy: legacy)
    }

    /// A suite of its own so these never touch the real app's settings.
    private func isolatedDefaults() -> UserDefaults {
        let suite = "prbar.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    // MARK: - persistence

    func testNoFileIsWrittenUntilSomethingChanges() throws {
        let p = try paths()
        let s = store(p)
        XCTAssertEqual(s.config, PRBarConfig())
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.file.path))

        s.defaults.maxCostUsdPerSubreview = 4
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.file.path))
    }

    func testUpsertPersistsAcrossInstances() throws {
        let p = try paths()
        let store1 = store(p)
        var cfg = RepoConfig.default
        cfg.repoGlobs = ["acme/infra"]
        store1.upsert(cfg)
        XCTAssertEqual(store1.userConfigs.count, 1)

        let store2 = store(p)
        XCTAssertEqual(store2.userConfigs.count, 1)
        XCTAssertEqual(store2.userConfigs.first?.repoGlobs, ["acme/infra"])
    }

    func testRemoveDropsRule() throws {
        let p = try paths()
        let s = store(p)
        var cfg = RepoConfig.default
        cfg.repoGlobs = ["acme/x"]
        s.upsert(cfg)
        s.remove(id: cfg.id)

        XCTAssertEqual(store(p).userConfigs.count, 0)
    }

    func testEditRepoGlobsKeepsIdentityInMemory() throws {
        let s = store(try paths())
        var cfg = RepoConfig.default
        cfg.repoGlobs = ["acme/x"]
        s.upsert(cfg)

        var renamed = cfg
        renamed.repoGlobs = ["acme/y"]
        s.upsert(renamed)

        XCTAssertEqual(s.userConfigs.count, 1)
        XCTAssertEqual(s.userConfigs.first?.id, cfg.id)
        XCTAssertEqual(s.userConfigs.first?.repoGlobs, ["acme/y"])
    }

    func testSetAllPreservesOrder() throws {
        let p = try paths()
        let s = store(p)
        var a = RepoConfig.default; a.repoGlobs = ["acme/a"]
        var b = RepoConfig.default; b.repoGlobs = ["acme/b"]
        var c = RepoConfig.default; c.repoGlobs = ["acme/c"]
        s.setAll([c, a, b])

        XCTAssertEqual(store(p).userConfigs.map(\.repoGlobs), [["acme/c"], ["acme/a"], ["acme/b"]])
    }

    func testAgentDefaultsPersist() throws {
        let p = try paths()
        let s = store(p)
        s.defaultProvider = .codex
        s.defaultClaudeModel = ""
        s.defaultCodexEffort = "high"

        let reloaded = store(p)
        XCTAssertEqual(reloaded.defaultProvider, .codex)
        XCTAssertEqual(reloaded.defaultClaudeModel, "", "empty means pass no flag, distinct from unset")
        XCTAssertNil(reloaded.defaultCodexModel)
        XCTAssertEqual(reloaded.defaultCodexEffort, "high")
    }

    // MARK: - review defaults

    func testReviewDefaultsPersistAcrossInstances() throws {
        let p = try paths()
        let s = store(p)
        s.defaults.maxCostUsdPerSubreview = 8.0
        s.defaults.toolMode = .minimal

        let reloaded = store(p)
        XCTAssertEqual(reloaded.defaults.maxCostUsdPerSubreview, 8.0)
        XCTAssertEqual(reloaded.defaults.toolMode, .minimal)
    }

    func testResolveFoldsDefaultsIntoTheMatchingRule() throws {
        let s = store(try paths())
        s.defaults.maxCostUsdPerSubreview = 6.0
        s.defaults.reviewTimeoutSeconds = 1200

        var rule = RepoConfig.default
        rule.repoGlobs = ["acme/infra"]
        rule.reviewTimeoutSeconds = 120
        s.upsert(rule)

        let matched = s.resolve(owner: "acme", repo: "infra")
        XCTAssertEqual(matched.reviewTimeoutSeconds, 120, "rule overrides")
        XCTAssertEqual(matched.maxCostUsdPerSubreview, 6.0, "rest inherits")

        let unmatched = s.resolve(owner: "other", repo: "thing")
        XCTAssertEqual(unmatched.reviewTimeoutSeconds, 1200)
        XCTAssertEqual(unmatched.maxCostUsdPerSubreview, 6.0)
    }

    func testEditingDefaultsFiresOnChange() throws {
        let s = store(try paths())
        var fired = 0
        s.onChange = { fired += 1 }

        s.defaults.maxCostUsdPerSubreview = 2.0
        XCTAssertEqual(fired, 1)

        // Re-assigning the same value shouldn't churn the resolvers or
        // trigger a re-poll — SwiftUI writes bindings back on every edit.
        s.defaults.maxCostUsdPerSubreview = 2.0
        XCTAssertEqual(fired, 1)
    }

    /// The resolver is a snapshot: a stale one must not observe later
    /// edits, and `onChange` is what hands out a fresh one.
    func testMakeResolverSnapshotsDefaults() throws {
        let s = store(try paths())
        s.defaults.maxCostUsdPerSubreview = 1.0
        let resolver = s.makeResolver()

        s.defaults.maxCostUsdPerSubreview = 9.0

        XCTAssertEqual(resolver("acme", "x").maxCostUsdPerSubreview, 1.0)
        XCTAssertEqual(s.makeResolver()("acme", "x").maxCostUsdPerSubreview, 9.0)
    }

    // MARK: - outside edits

    func testOutsideEditIsPickedUpAndFiresOnChange() throws {
        let p = try paths()
        let s = store(p)
        var rule = RepoConfig.default
        rule.repoGlobs = ["acme/x"]
        s.upsert(rule)
        var fired = 0
        s.onChange = { fired += 1 }

        try ConfigFile.write("""
        defaults:
          maxCostUsdPerSubreview: 9
        repos:
          - repoGlobs: [acme/x]
            reviewDrafts: true
        """, to: p.file)
        s.reloadIfChanged()

        XCTAssertEqual(fired, 1)
        XCTAssertEqual(s.defaults.maxCostUsdPerSubreview, 9)
        XCTAssertEqual(s.userConfigs.first?.reviewDrafts, true)
        XCTAssertEqual(s.userConfigs.first?.id, rule.id, "same rule keeps its Settings identity")
        XCTAssertNil(s.loadIssue)

        // Nothing changed on disk: no reload, no churn.
        s.reloadIfChanged()
        XCTAssertEqual(fired, 1)
    }

    func testBrokenOutsideEditKeepsTheCurrentConfig() throws {
        let p = try paths()
        let s = store(p)
        s.defaults.maxCostUsdPerSubreview = 4
        var fired = 0
        s.onChange = { fired += 1 }

        try ConfigFile.write("defaults: [unclosed", to: p.file)
        s.reloadIfChanged()

        XCTAssertEqual(fired, 0)
        XCTAssertEqual(s.defaults.maxCostUsdPerSubreview, 4)
        XCTAssertNotNil(s.loadIssue)
    }

    func testBrokenFileAtLaunchFallsBackToLastGood() throws {
        let p = try paths()
        store(p).defaults.maxCostUsdPerSubreview = 4

        try ConfigFile.write("defaults: [unclosed", to: p.file)
        let s = store(p)

        XCTAssertEqual(s.defaults.maxCostUsdPerSubreview, 4)
        XCTAssertNotNil(s.loadIssue)
        XCTAssertEqual(try String(contentsOf: p.file, encoding: .utf8), "defaults: [unclosed",
                       "the broken file is the user's to fix, not ours to overwrite")
    }

    func testUnknownKeysSurfaceAsWarnings() throws {
        let p = try paths()
        try ConfigFile.write("defaults:\n  maxCostUsd: 2\n", to: p.file)
        let s = store(p)
        XCTAssertNil(s.loadIssue)
        XCTAssertEqual(s.warnings.count, 1)
    }

    // MARK: - migration

    func testMigratesLegacySettingsOnce() throws {
        let p = try paths()
        let container = PRBarModelContainer.inMemory()
        let ud = isolatedDefaults()

        var rule = RepoConfig(repoGlobs: ["acme/infra"], rootPatterns: ["kernel-*"])
        rule.maxCostUsdPerSubreview = 2
        let context = ModelContext(container)
        context.insert(RepoConfigEntry(id: rule.id, orderIndex: 0, payload: try JSONEncoder().encode(rule)))
        var second = RepoConfig(repoGlobs: ["acme/web"])
        second.excluded = true
        context.insert(RepoConfigEntry(id: second.id, orderIndex: 1, payload: try JSONEncoder().encode(second)))
        try context.save()

        var legacyDefaults = ReviewDefaults()
        legacyDefaults.reviewTimeoutSeconds = 900
        ud.set(try JSONEncoder().encode(legacyDefaults), forKey: "reviewDefaults")
        ud.set("codex", forKey: "defaultProviderId")
        ud.set("", forKey: "defaultClaudeModel")
        ud.set("high", forKey: "defaultCodexEffort")

        let legacy: @MainActor () -> PRBarConfig? = {
            LegacyConfigMigration.read(container: container, userDefaults: ud)
        }
        let s = store(p, legacy: legacy)

        XCTAssertTrue(s.migratedFromLegacy)
        XCTAssertEqual(s.userConfigs.map(\.repoGlobs), [["acme/infra"], ["acme/web"]])
        XCTAssertEqual(s.userConfigs.first?.maxCostUsdPerSubreview, 2)
        XCTAssertEqual(s.userConfigs.first?.rootPatterns, ["kernel-*"])
        XCTAssertEqual(s.userConfigs.last?.excluded, true)
        XCTAssertEqual(s.defaults.reviewTimeoutSeconds, 900)
        XCTAssertEqual(s.defaultProvider, .codex)
        XCTAssertEqual(s.defaultClaudeModel, "")
        XCTAssertNil(s.defaultCodexModel, "absent key stays unset")
        XCTAssertEqual(s.defaultCodexEffort, "high")
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.file.path))

        // The file now exists, so later launches read it and ignore the
        // legacy store entirely, even if it still holds older data.
        let again = store(p, legacy: legacy)
        XCTAssertFalse(again.migratedFromLegacy)
        again.defaults.reviewTimeoutSeconds = 100
        XCTAssertEqual(store(p, legacy: legacy).defaults.reviewTimeoutSeconds, 100)

        // Legacy data is left in place for an older build to find.
        XCTAssertNotNil(ud.data(forKey: "reviewDefaults"))
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<RepoConfigEntry>()), 2)
    }

    func testNothingToMigrateLeavesNoFile() throws {
        let p = try paths()
        let ud = isolatedDefaults()
        let container = PRBarModelContainer.inMemory()
        let s = store(p, legacy: { LegacyConfigMigration.read(container: container, userDefaults: ud) })
        XCTAssertFalse(s.migratedFromLegacy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.file.path))
    }

    func testAutoProviderMigratesAsAuto() throws {
        let ud = isolatedDefaults()
        ud.set("auto", forKey: "defaultProviderId")
        let migrated = LegacyConfigMigration.read(container: PRBarModelContainer.inMemory(), userDefaults: ud)
        XCTAssertEqual(migrated?.defaultProvider, .auto)
    }
}
