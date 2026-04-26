import Foundation
import Observation

/// JSON-backed persistence for user-edited `RepoConfig`s.
///
/// File layout:
/// ```
/// ~/Library/Application Support/io.synq.prbar/repo-configs.json
/// ```
///
/// Resolution order when looking up a config for a PR:
///   1. user-defined configs (most-specific match wins, in list order)
///   2. built-ins (`RepoConfig.builtins`)
///   3. `RepoConfig.default`
///
/// Loaded eagerly on init; saves are write-through. SwiftData migration
/// is a follow-up — keeping this small and Codable for now.
@MainActor
@Observable
final class RepoConfigStore {
    private(set) var userConfigs: [RepoConfig]

    @ObservationIgnored
    private let fileURL: URL

    init(fileURL: URL = RepoConfigStore.defaultURL) {
        self.fileURL = fileURL
        self.userConfigs = Self.loadFromDisk(at: fileURL)
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
        // Snapshot the list at resolver-creation time. The worker swaps
        // its closure when configs change (see PRBarApp wiring).
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

    static let defaultURL: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("io.synq.prbar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("repo-configs.json")
    }()

    private static func loadFromDisk(at url: URL) -> [RepoConfig] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return (try? decoder.decode([RepoConfig].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(userConfigs) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
