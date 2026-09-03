import Foundation
import Observation
import SwiftData

/// SwiftData-backed persistence for user-edited `RepoConfig`s, plus the
/// app-level `ReviewDefaults` those rules override.
///
/// Resolution order when looking up a config for a PR:
///   1. user-defined rules (most-specific match wins, in list order)
///   2. built-ins (`RepoConfig.builtins`)
///   3. `RepoConfig.default` (a rule that overrides nothing)
///
/// …then every field the winning rule left `nil` resolves from
/// `defaults`. `resolve` and `makeResolver` are the only two places a
/// `ResolvedRepoConfig` is minted, so no caller can accidentally read a
/// rule's raw `nil` as a value.
///
/// Loaded eagerly on init; saves are write-through. The `RepoConfig`
/// struct is stored as a JSON blob in `RepoConfigEntry.payload` so its
/// shape can evolve without a SwiftData migration each time.
/// `ReviewDefaults` is a single JSON blob in `UserDefaults` — one row's
/// worth of data, and it needs to be readable before the model container
/// is up.
@MainActor
@Observable
final class RepoConfigStore {
    private(set) var userConfigs: [RepoConfig]

    /// Every provider a per-repo override currently points at. Single
    /// source for the `ProviderRelevance` call sites (General Settings
    /// picker labels, Diagnostics tool list) so the `compactMap` predicate
    /// can't drift between them.
    var providerOverrides: [ProviderID] {
        userConfigs.compactMap(\.providerOverride)
    }

    /// App-level values every rule inherits from. Edited in Settings →
    /// Review defaults.
    var defaults: ReviewDefaults {
        didSet {
            guard defaults != oldValue else { return }
            saveDefaults()
            onChange?()
        }
    }

    @ObservationIgnored
    private let container: ModelContainer

    @ObservationIgnored
    private let context: ModelContext

    @ObservationIgnored
    private let userDefaults: UserDefaults

    init(
        container: ModelContainer = PRBarModelContainer.live(),
        userDefaults: UserDefaults = .standard
    ) {
        self.container = container
        self.context = ModelContext(container)
        self.userDefaults = userDefaults
        self.userConfigs = Self.loadFromContext(context)
        self.defaults = Self.loadDefaults(from: userDefaults)
    }

    /// Resolve the effective config for a given owner/repo. User rules win
    /// over built-ins; `RepoConfig.default` is the final fallback, and the
    /// app defaults fill in whatever the winning rule doesn't override.
    func resolve(owner: String, repo: String) -> ResolvedRepoConfig {
        rule(owner: owner, repo: repo).resolved(with: defaults)
    }

    /// The matching rule *without* defaults folded in — for the Settings
    /// UI, which needs to show whether a field is overridden or inherited.
    func rule(owner: String, repo: String) -> RepoConfig {
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
    /// Snapshots both the rules and the defaults, so a resolver handed out
    /// before an edit keeps resolving against the state it was made with —
    /// `onChange` hands out a fresh one.
    nonisolated func makeResolver() -> @Sendable (String, String) -> ResolvedRepoConfig {
        let (snapshot, defaults) = MainActor.assumeIsolated { (userConfigs, self.defaults) }
        return { owner, repo in
            let nameWithOwner = "\(owner)/\(repo)"
            if let user = snapshot.first(where: { $0.matches(nameWithOwner: nameWithOwner) }) {
                return user.resolved(with: defaults)
            }
            return RepoConfig.match(owner: owner, repo: repo).resolved(with: defaults)
        }
    }

    // MARK: - persistence

    private static func loadDefaults(from userDefaults: UserDefaults) -> ReviewDefaults {
        guard let data = userDefaults.data(forKey: ReviewDefaults.storageKey),
              let decoded = try? JSONDecoder().decode(ReviewDefaults.self, from: data)
        else { return ReviewDefaults() }
        return decoded
    }

    private func saveDefaults() {
        guard let data = try? JSONEncoder().encode(defaults) else { return }
        userDefaults.set(data, forKey: ReviewDefaults.storageKey)
    }

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
