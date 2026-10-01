import Foundation

/// Where the app keeps its files. Under XCTest (the test host is this
/// app) everything points into one throwaway directory per process, so a
/// test run never reads or rewrites the developer's real state.
enum AppPaths {
    static var state: URL {
        AppDelegate.isHostingTests ? testRoot.appendingPathComponent("state") : ConfigLocation.stateDirectory()
    }

    static var cache: URL {
        AppDelegate.isHostingTests ? testRoot.appendingPathComponent("cache") : CacheLocation.directory()
    }

    static var history: URL { state.appendingPathComponent("history") }

    /// Whether the pre-file SwiftData store should be read as a fallback.
    /// Never under XCTest: that store is the developer's real one.
    static var readsLegacyStore: Bool { !AppDelegate.isHostingTests }

    private static let testRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("prbar-test-host-\(UUID().uuidString)")
}
