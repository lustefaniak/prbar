import Foundation
import Observation
import SwiftData

/// The app's handle on `prbar.yaml`: the repo rules, the app-level
/// `ReviewDefaults` they override, and the agent defaults (provider,
/// model, effort). The file is the source of truth and the same one the
/// `prbar-review` CLI reads.
///
/// Resolution order when looking up a config for a PR:
///   1. user-defined rules (first match wins, in file order)
///   2. built-ins (`RepoConfig.builtins`)
///   3. `RepoConfig.default` (a rule that overrides nothing)
///
/// …then every field the winning rule left `nil` resolves from
/// `defaults`. `resolve` and `makeResolver` are the only two places a
/// `ResolvedRepoConfig` is minted, so no caller can accidentally read a
/// rule's raw `nil` as a value.
///
/// Edits from Settings write the file straight away (temp file + rename).
/// Edits made to the file by hand, or by another tool, are picked up by
/// polling; a file that fails to parse leaves the current config in
/// place and surfaces the error in `loadIssue`. At launch a broken file
/// falls back to the last copy that loaded cleanly.
@MainActor
@Observable
final class RepoConfigStore {
    private(set) var config: PRBarConfig

    /// Why the file on disk isn't what's in effect, if it isn't: a parse
    /// error, or the fact that the last-good copy was loaded instead.
    private(set) var loadIssue: String?

    /// Non-fatal problems with the file in effect (unknown keys).
    private(set) var warnings: [String] = []

    /// Set when this launch created the file from the pre-file settings.
    private(set) var migratedFromLegacy = false

    @ObservationIgnored let fileURL: URL
    @ObservationIgnored private let lastGoodURL: URL?
    @ObservationIgnored private var lastSeenData: Data?
    @ObservationIgnored private var watchTask: Task<Void, Never>?

    /// Hook fired after every change, from Settings or from the file.
    /// Used by `AppDelegate` to refresh the resolvers and agent defaults so
    /// edits affect the next review without a restart.
    @ObservationIgnored
    var onChange: (@MainActor () -> Void)?

    var userConfigs: [RepoConfig] { config.repos }

    /// App-level values every rule inherits from. Edited in Settings →
    /// Review defaults.
    var defaults: ReviewDefaults {
        get { config.defaults }
        set { mutate { $0.defaults = newValue } }
    }

    var defaultProvider: ProviderChoice {
        get { config.defaultProvider }
        set { mutate { $0.defaultProvider = newValue } }
    }

    var defaultClaudeModel: String? {
        get { config.defaultClaudeModel }
        set { mutate { $0.defaultClaudeModel = newValue } }
    }

    var defaultClaudeEffort: String? {
        get { config.defaultClaudeEffort }
        set { mutate { $0.defaultClaudeEffort = newValue } }
    }

    var defaultCodexModel: String? {
        get { config.defaultCodexModel }
        set { mutate { $0.defaultCodexModel = newValue } }
    }

    var defaultCodexEffort: String? {
        get { config.defaultCodexEffort }
        set { mutate { $0.defaultCodexEffort = newValue } }
    }

    /// Every provider a per-repo override currently points at. Single
    /// source for the `ProviderRelevance` call sites (General Settings
    /// picker labels, Diagnostics tool list) so the `compactMap` predicate
    /// can't drift between them.
    var providerOverrides: [ProviderID] {
        userConfigs.compactMap(\.providerOverride)
    }

    /// - Parameters:
    ///   - legacy: settings from before the file existed. Consulted only
    ///     when the file is missing; whatever it returns is written out as
    ///     the new file. Nil disables migration (tests, screenshots).
    ///   - watch: poll the file for outside edits.
    init(
        fileURL: URL = ConfigLocation.userConfigURL(),
        lastGoodURL: URL? = ConfigLocation.lastGoodURL(),
        legacy: (@MainActor () -> PRBarConfig?)? = nil,
        watch: Bool = false
    ) {
        self.fileURL = fileURL
        self.lastGoodURL = lastGoodURL
        self.config = PRBarConfig()
        loadAtLaunch(legacy: legacy)
        if watch { startWatching() }
    }

    /// The production store: the user's config file, migrated from the
    /// SwiftData + UserDefaults settings on first launch, watched for edits.
    static func live() -> RepoConfigStore {
        RepoConfigStore(
            legacy: { LegacyConfigMigration.read(container: PRBarModelContainer.live(), userDefaults: .standard) },
            watch: true
        )
    }

    // MARK: - lookups

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

    /// Closure form for injection into `ReviewQueueWorker.configResolver`.
    /// A snapshot: a resolver handed out before an edit keeps resolving
    /// against the state it was made with — `onChange` hands out a fresh one.
    nonisolated func makeResolver() -> @Sendable (String, String) -> ResolvedRepoConfig {
        MainActor.assumeIsolated { config.resolver() }
    }

    // MARK: - edits

    /// Replace the user-config list and persist.
    func setAll(_ configs: [RepoConfig]) {
        mutate { $0.repos = configs }
    }

    /// Upsert by stable `id`.
    func upsert(_ rule: RepoConfig) {
        mutate { config in
            if let idx = config.repos.firstIndex(where: { $0.id == rule.id }) {
                config.repos[idx] = rule
            } else {
                config.repos.append(rule)
            }
        }
    }

    func remove(id: UUID) {
        mutate { $0.repos.removeAll { $0.id == id } }
    }

    private func mutate(_ body: (inout PRBarConfig) -> Void) {
        var next = config
        body(&next)
        // SwiftUI writes bindings back on every edit; an unchanged value
        // must not rewrite the file or churn the resolvers.
        guard next != config else { return }
        config = next
        save()
        onChange?()
    }

    // MARK: - file I/O

    private func save() {
        do {
            let text = try ConfigFile.encode(config)
            try ConfigFile.write(text, to: fileURL)
            lastSeenData = Data(text.utf8)
            loadIssue = nil
            warnings = []
            saveLastGood(text)
        } catch {
            loadIssue = "Could not save \(fileURL.path): \(error.localizedDescription)"
            PRBarLog.config.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadAtLaunch(legacy: (@MainActor () -> PRBarConfig?)?) {
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                lastSeenData = data
                try apply(data: data, path: fileURL.path)
            } catch {
                loadIssue = "\(error.localizedDescription). Using the last config that loaded."
                PRBarLog.config.error("load failed: \(error.localizedDescription, privacy: .public)")
                loadLastGood()
            }
            return
        }
        if let migrated = legacy?() {
            config = migrated
            migratedFromLegacy = true
            PRBarLog.config.notice("migrated legacy settings to \(self.fileURL.path, privacy: .public)")
            save()
        }
    }

    private func loadLastGood() {
        guard let lastGoodURL, let data = try? Data(contentsOf: lastGoodURL) else { return }
        if let text = String(data: data, encoding: .utf8),
           let loaded = try? ConfigFile.decode(text, path: lastGoodURL.path) {
            config = loaded.config
        }
    }

    private func apply(data: Data, path: String) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConfigFile.Error.invalid(path: path, reason: "not valid UTF-8")
        }
        let loaded = try ConfigFile.decode(text, path: path)
        var next = loaded.config
        next.repos = Self.keepingIdentity(next.repos, from: config.repos)
        config = next
        warnings = loaded.warnings
        loadIssue = nil
        saveLastGood(text)
    }

    /// The file carries no rule ids, so a reload would otherwise hand
    /// every rule a fresh UUID and drop the Settings selection. Reuse the
    /// old id for a rule at the same position with the same globs.
    private static func keepingIdentity(_ fresh: [RepoConfig], from old: [RepoConfig]) -> [RepoConfig] {
        fresh.enumerated().map { index, rule in
            var rule = rule
            if index < old.count, old[index].repoGlobs == rule.repoGlobs {
                rule.id = old[index].id
            }
            return rule
        }
    }

    private func saveLastGood(_ text: String) {
        guard let lastGoodURL else { return }
        try? ConfigFile.write(text, to: lastGoodURL)
    }

    /// Re-read the file if it changed since we last read or wrote it.
    /// Called by the poller; exposed for tests.
    func reloadIfChanged() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard data != lastSeenData else { return }
        lastSeenData = data
        let before = config
        do {
            try apply(data: data, path: fileURL.path)
        } catch {
            loadIssue = "\(error.localizedDescription). Keeping the previous config."
            PRBarLog.config.error("reload failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        if config != before { onChange?() }
    }

    /// Polling rather than FSEvents: editors save via rename, which a
    /// vnode watch on the file misses, and a 2 s stat of one small file
    /// costs nothing.
    private func startWatching() {
        watchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.reloadIfChanged()
            }
        }
    }

    deinit {
        watchTask?.cancel()
    }
}
