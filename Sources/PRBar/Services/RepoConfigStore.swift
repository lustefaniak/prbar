import Foundation
import Observation
import SwiftData

/// SwiftData-backed persistence for user-edited `RepoConfig`s.
///
/// Resolution order when looking up a config for a PR:
///   1. user-defined configs (most-specific match wins, in list order)
///   2. built-ins (`RepoConfig.builtins`)
///   3. `RepoConfig.default`
///
/// Loaded eagerly on init; saves are write-through. The `RepoConfig`
/// struct is stored as a JSON blob in `RepoConfigEntry.payload` so its
/// shape can evolve without a SwiftData migration each time.
@MainActor
@Observable
final class RepoConfigStore {
    private(set) var userConfigs: [RepoConfig]

    @ObservationIgnored
    private let container: ModelContainer

    @ObservationIgnored
    private let context: ModelContext

    init(container: ModelContainer = PRBarModelContainer.live()) {
        self.container = container
        self.context = ModelContext(container)
        self.userConfigs = Self.loadFromContext(context)
    }

    /// Resolve the config for a given owner/repo. User configs win over
    /// built-ins; `RepoConfig.default` is the final fallback.
    func resolve(owner: String, repo: String) -> RepoConfig {
        let nameWithOwner = "\(owner)/\(repo)"
        if let user = userConfigs.first(where: { $0.matches(nameWithOwner: nameWithOwner) }) {
            return user
        }
        for builtin in RepoConfig.builtins where builtin.matches(nameWithOwner: nameWithOwner) {
            return builtin
        }
        return .default
    }

    /// Hook fired after every persisted change. Used by `PRBarApp` to
    /// refresh `ReviewQueueWorker.configResolver` so live edits affect the
    /// next review without a restart.
    @ObservationIgnored
    var onChange: (@MainActor () -> Void)?

    /// Replace the user-config list and persist.
    func setAll(_ configs: [RepoConfig]) {
        userConfigs = configs
        save()
        onChange?()
    }

    /// Upsert by `repoGlobs` identity (matched as exact-equal lists). Most
    /// editors will pass the original config plus a mutated copy; this
    /// keeps the list ordered.
    func upsert(_ config: RepoConfig) {
        if let idx = userConfigs.firstIndex(where: { $0.repoGlobs == config.repoGlobs }) {
            userConfigs[idx] = config
        } else {
            userConfigs.append(config)
        }
        save()
        onChange?()
    }

    func remove(repoGlobs: [String]) {
        userConfigs.removeAll { $0.repoGlobs == repoGlobs }
        save()
        onChange?()
    }

    /// Closure form for injection into `ReviewQueueWorker.configResolver`.
    nonisolated func makeResolver() -> @Sendable (String, String) -> RepoConfig {
        let snapshot = MainActor.assumeIsolated { userConfigs }
        return { owner, repo in
            let nameWithOwner = "\(owner)/\(repo)"
            if let user = snapshot.first(where: { $0.matches(nameWithOwner: nameWithOwner) }) {
                return user
            }
            return RepoConfig.match(owner: owner, repo: repo)
        }
    }

    // MARK: - persistence

    private static func loadFromContext(_ context: ModelContext) -> [RepoConfig] {
        var descriptor = FetchDescriptor<RepoConfigEntry>(
            sortBy: [SortDescriptor(\RepoConfigEntry.orderIndex)]
        )
        descriptor.includePendingChanges = false
        guard let rows = try? context.fetch(descriptor) else { return [] }
        let decoder = JSONDecoder()
        return rows.compactMap { try? decoder.decode(RepoConfig.self, from: $0.payload) }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let descriptor = FetchDescriptor<RepoConfigEntry>(
            sortBy: [SortDescriptor(\RepoConfigEntry.orderIndex)]
        )
        let existing = (try? context.fetch(descriptor)) ?? []

        // Encode upfront. A row whose encode fails is *skipped* — we
        // leave the existing on-disk row untouched rather than the
        // earlier delete-all pattern, which silently nuked every config
        // if a single one couldn't serialize.
        var encoded: [(orderIndex: Int, payload: Data)] = []
        for (idx, config) in userConfigs.enumerated() {
            guard let payload = try? encoder.encode(config) else {
                NSLog("RepoConfigStore.save: skipped encode failure at index %d (globs=%@)",
                      idx, String(describing: config.repoGlobs))
                continue
            }
            encoded.append((idx, payload))
        }

        // In-place update by orderIndex. Preserves SwiftData row identity
        // across edits (no churn per keystroke) and means an error
        // mid-flight only affects the row that actually failed.
        var existingByIdx = Dictionary(uniqueKeysWithValues: existing.map { ($0.orderIndex, $0) })
        for entry in encoded {
            if let row = existingByIdx.removeValue(forKey: entry.orderIndex) {
                if row.payload != entry.payload {
                    row.payload = entry.payload
                }
            } else {
                context.insert(RepoConfigEntry(
                    orderIndex: entry.orderIndex, payload: entry.payload
                ))
            }
        }

        // Anything still in `existingByIdx` is an orphan — its
        // orderIndex is past the new tail, so delete it.
        for (_, row) in existingByIdx {
            context.delete(row)
        }
        try? context.save()
    }
}
