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

    /// Upsert by stable `id`. Editing repoGlobs no longer invalidates
    /// the row — id is what the SwiftData row matches against too.
    func upsert(_ config: RepoConfig) {
        if let idx = userConfigs.firstIndex(where: { $0.id == config.id }) {
            userConfigs[idx] = config
        } else {
            userConfigs.append(config)
        }
        save()
        onChange?()
    }

    func remove(id: UUID) {
        userConfigs.removeAll { $0.id == id }
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
        var result: [RepoConfig] = []
        for row in rows {
            guard var cfg = try? decoder.decode(RepoConfig.self, from: row.payload)
            else { continue }
            // Force config.id to mirror the SwiftData row id. Stabilizes
            // legacy rows whose payload predates the `id` field (the
            // decoder otherwise gives them a fresh UUID per read), and
            // reaffirms the invariant for newer rows.
            cfg.id = row.id
            result.append(cfg)
        }
        return result
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
        var encoded: [(id: UUID, orderIndex: Int, payload: Data)] = []
        for (idx, config) in userConfigs.enumerated() {
            guard let payload = try? encoder.encode(config) else {
                NSLog("RepoConfigStore.save: skipped encode failure at index %d (globs=%@)",
                      idx, String(describing: config.repoGlobs))
                continue
            }
            encoded.append((config.id, idx, payload))
        }

        // Match by stable `id` so editing repoGlobs or reordering the
        // list never churns SwiftData row identity. Anything in
        // `existingById` not overwritten below is an orphan — delete.
        var existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for entry in encoded {
            if let row = existingById.removeValue(forKey: entry.id) {
                if row.payload != entry.payload {
                    row.payload = entry.payload
                }
                if row.orderIndex != entry.orderIndex {
                    row.orderIndex = entry.orderIndex
                }
            } else {
                context.insert(RepoConfigEntry(
                    id: entry.id, orderIndex: entry.orderIndex, payload: entry.payload
                ))
            }
        }
        for (_, row) in existingById {
            context.delete(row)
        }
        try? context.save()
    }
}
