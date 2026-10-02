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

    func testRepositoryListsPersistAcrossInstances() throws {
        let p = try paths()
        let store1 = store(p)
        store1.replace(with: {
            var c = store1.config
            c.repositories = RepositoryScope(triage: ["acme/*"], hide: ["acme/infra"])
            return c
        }())
        XCTAssertEqual(store(p).config.repositories.hide, ["acme/infra"])
        XCTAssertEqual(store(p).config.repositories.triage, ["acme/*"])
    }

    /// `repos:` is refused until converted, and nothing Settings does may
    /// write over it meanwhile: the config in effect is the shipped
    /// defaults, so a save would erase the entries.
    func testAReposKeyIsRefusedAndNeverOverwritten() throws {
        let p = try paths()
        let old = "repos:\n  - repoGlobs: [acme/x]\n    reviewDrafts: true\n"
        try ConfigFile.write(old, to: p.file)
        let s = store(p)
        XCTAssertTrue(s.needsConversion)
        XCTAssertTrue(s.loadIssue?.contains("rules convert") == true, s.loadIssue ?? "")

        s.defaults.maxCostUsdPerSubreview = 4
        XCTAssertEqual(try String(contentsOf: p.file, encoding: .utf8), old)
        XCTAssertTrue(s.loadIssue?.contains("Not saved") == true, s.loadIssue ?? "")
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

    func testResolveFoldsDefaultsIntoWhatTheRulesSet() throws {
        let p = try paths()
        let rules = p.file.deletingLastPathComponent().appendingPathComponent("rules/configure")
        try FileManager.default.createDirectory(at: rules, withIntermediateDirectories: true)
        try """
            name: infra
            rule:
              match:
                - condition: repo.full_name == "acme/infra"
                  output: {rule: infra, review_timeout_seconds: 120}
            """.write(to: rules.appendingPathComponent("10-infra.yaml"), atomically: true, encoding: .utf8)
        let s = store(p)
        s.defaults.maxCostUsdPerSubreview = 6.0
        s.defaults.reviewTimeoutSeconds = 1200

        let matched = s.resolve(owner: "acme", repo: "infra")
        XCTAssertEqual(matched.reviewTimeoutSeconds, 120, "the rule sets it")
        XCTAssertEqual(matched.maxCostUsdPerSubreview, 6.0, "rest from defaults")

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
        s.defaults.maxCostUsdPerSubreview = 4
        var fired = 0
        s.onChange = { fired += 1 }

        try ConfigFile.write("""
        defaults:
          maxCostUsdPerSubreview: 9
        repositories:
          hide: [acme/x]
        """, to: p.file)
        s.reloadIfChanged()

        XCTAssertEqual(fired, 1)
        XCTAssertEqual(s.defaults.maxCostUsdPerSubreview, 9)
        XCTAssertTrue(s.resolve(owner: "acme", repo: "x").excluded)
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
        // The repo rules became a configure rule beside the file.
        let infra = s.resolve(owner: "acme", repo: "infra")
        XCTAssertEqual(infra.maxCostUsdPerSubreview, 2)
        XCTAssertEqual(infra.rootPatterns, ["kernel-*"])
        XCTAssertTrue(s.resolve(owner: "acme", repo: "web").excluded)
        XCTAssertEqual(s.config.repositories.hide, ["acme/web"])
        XCTAssertFalse(try String(contentsOf: p.file, encoding: .utf8).contains("repos:"))
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
