import XCTest
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
        store.remove(repoGlobs: ["acme/x"])

        let reloaded = RepoConfigStore(container: container)
        XCTAssertEqual(reloaded.userConfigs.count, 0)
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
}
