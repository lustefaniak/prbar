import Foundation

extension RuntimeEnvironment {
    /// The app's runtime environment: the shared XDG files (or a throwaway
    /// directory under XCTest, via `AppPaths`), plus read-only fallbacks
    /// into what the app kept before those files existed — the SwiftData
    /// store and a few UserDefaults keys — so an upgrade loses nothing and
    /// re-runs no review. The fallbacks are consulted only while the
    /// corresponding file is missing.
    static func app() -> RuntimeEnvironment {
        var env = RuntimeEnvironment(
            configFile: AppDelegate.isHostingTests
                ? AppPaths.state.appendingPathComponent("prbar.yaml")
                : ConfigLocation.userConfigURL(),
            lastGoodConfig: AppDelegate.isHostingTests ? nil : ConfigLocation.lastGoodURL(),
            stateDirectory: AppPaths.state,
            cacheDirectory: AppPaths.cache,
            watchConfig: !AppDelegate.isHostingTests
        )
        guard AppPaths.readsLegacyStore else { return env }
        env.legacyConfig = { LegacyConfigMigration.read(container: PRBarModelContainer.live(), userDefaults: .standard) }
        env.legacyReviewStates = { LegacyStateMigration.reviewStates(PRBarModelContainer.live()) }
        env.legacyInbox = { LegacyStateMigration.inboxSnapshot(PRBarModelContainer.live()) }
        env.legacyNotified = {
            UserDefaults.standard.data(forKey: "readinessNotifiedSHAs")
                .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
        }
        return env
    }
}
