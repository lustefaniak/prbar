import Foundation
import SwiftData

/// Reads the settings PRBar kept before `prbar.yaml` existed, so the first
/// launch with the file can write them out instead of starting blank:
///
/// - repo rules: `RepoConfigEntry` rows in the SwiftData store
/// - app-level review defaults: the `reviewDefaults` JSON blob in UserDefaults
/// - agent defaults: the `defaultProviderId`, `defaultClaudeModel`,
///   `defaultClaudeEffort`, `defaultCodexModel`, `defaultCodexEffort` keys
///
/// Read-only: nothing is deleted, so going back to an older build still
/// finds its settings where it left them.
enum LegacyConfigMigration {
    static let reviewDefaultsKey = "reviewDefaults"
    static let agentKeys = [
        "defaultProviderId",
        "defaultClaudeModel", "defaultClaudeEffort",
        "defaultCodexModel", "defaultCodexEffort",
    ]

    /// Nil when there is nothing to migrate: a fresh install keeps the
    /// file absent until the user changes something.
    @MainActor
    static func read(container: ModelContainer, userDefaults: UserDefaults) -> PRBarConfig? {
        let repos = readRepoRules(container: container)
        let defaultsData = userDefaults.data(forKey: reviewDefaultsKey)
        let hasAgentKeys = agentKeys.contains { userDefaults.object(forKey: $0) != nil }
        guard !repos.isEmpty || defaultsData != nil || hasAgentKeys else { return nil }

        var config = PRBarConfig()
        config.legacyRepos = repos
        if let defaultsData,
           let decoded = try? JSONDecoder().decode(ReviewDefaults.self, from: defaultsData) {
            config.defaults = decoded
        }
        switch userDefaults.string(forKey: "defaultProviderId") {
        case nil, ProviderID.autoSentinel?:
            config.defaultProvider = .auto
        case let raw?:
            config.defaultProvider = ProviderID(rawValue: raw).map(ProviderChoice.init) ?? .auto
        }
        // Absent key = PRBar's compiled-in default; present-but-empty is a
        // deliberate "pass no flag", which the file keeps as "".
        config.defaultClaudeModel = userDefaults.string(forKey: "defaultClaudeModel")
        config.defaultClaudeEffort = userDefaults.string(forKey: "defaultClaudeEffort")
        config.defaultCodexModel = userDefaults.string(forKey: "defaultCodexModel")
        config.defaultCodexEffort = userDefaults.string(forKey: "defaultCodexEffort")
        return config
    }

    @MainActor
    private static func readRepoRules(container: ModelContainer) -> [RepoConfig] {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<RepoConfigEntry>(
            sortBy: [SortDescriptor(\RepoConfigEntry.orderIndex)]
        )
        descriptor.includePendingChanges = false
        guard let rows = try? context.fetch(descriptor) else { return [] }
        let decoder = JSONDecoder()
        return rows.compactMap { row in
            guard var rule = try? decoder.decode(RepoConfig.self, from: row.payload) else { return nil }
            rule.id = row.id
            return rule
        }
    }
}
