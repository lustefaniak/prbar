import Foundation
import Observation

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

    /// Bumped on every change to `config`, from Settings or from the file,
    /// so front ends editing a copy can tell which state is newer and
    /// whether the file moved under an edit.
    private(set) var revision = 0

    @ObservationIgnored let fileURL: URL
    @ObservationIgnored private let lastGoodURL: URL?
    @ObservationIgnored private var lastSeenData: Data?
    /// The rules directory as last read.
    @ObservationIgnored private var lastSeenRules: [String: Data]?

    /// Why the rules in effect aren't what's in the rules directory: they
    /// don't compile. At launch that leaves `Rules.unloaded` in effect,
    /// which posts nothing; later, the previous rules stay.
    private(set) var rulesIssue: String?

    @ObservationIgnored let rulesURL: URL
    /// The file still has `repos:`, which is refused until converted
    /// (`rules convert`). Nothing is saved meanwhile: a save would write
    /// the config in effect, the shipped defaults, over the entries.
    private(set) var needsConversion = false
    @ObservationIgnored private var watchTask: Task<Void, Never>?

    /// Hook fired after every change, from Settings or from the file.
    /// Used by `AppDelegate` to refresh the resolvers and agent defaults so
    /// edits affect the next review without a restart.
    @ObservationIgnored
    var onChange: (@MainActor () -> Void)?
    /// Rule changes coding agents proposed, waiting for the user.
    var proposals = RuleProposals()

    /// The repositories PRBar has seen in the inbox, so the config state
    /// can carry what the rules set for each: front ends show settings
    /// but can't run the rules.
    private(set) var knownRepositories: Set<String> = []

    func noteRepositories(_ prs: [InboxPR]) {
        let names = Set(prs.map(\.nameWithOwner))
        guard !names.isSubset(of: knownRepositories) else { return }
        knownRepositories.formUnion(names)
    }

    /// What the rules set for each known repository.
    var configuredRepositories: [String: RepoConfig] {
        var out: [String: RepoConfig] = [:]
        for name in knownRepositories {
            let parts = name.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            out[name] = config.rule(owner: parts[0], repo: parts[1])
        }
        return out
    }

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
        configuredRepositories.values.compactMap(\.providerOverride)
    }

    /// - Parameters:
    ///   - legacy: settings from before the file existed. Consulted only
    ///     when the file is missing; whatever it returns is written out as
    ///     the new file. Nil disables migration (tests, screenshots).
    ///   - watch: poll the file for outside edits.
    init(
        fileURL: URL = ConfigLocation.userConfigURL(),
        lastGoodURL: URL? = ConfigLocation.lastGoodURL(),
        rulesURL: URL? = nil,
        legacy: (@MainActor () -> PRBarConfig?)? = nil,
        watch: Bool = false
    ) {
        self.fileURL = fileURL
        self.lastGoodURL = lastGoodURL
        self.rulesURL = rulesURL ?? RuleDirectory.url(configFile: fileURL)
        self.config = PRBarConfig()
        loadAtLaunch(legacy: legacy)
        reloadRulesIfChanged()
        if watch { startWatching() }
    }

    // MARK: - lookups

    /// Resolve the effective config for a given owner/repo. User rules win
    /// over built-ins; `RepoConfig.default` is the final fallback, and the
    /// app defaults fill in whatever the winning rule doesn't override.
    func resolve(owner: String, repo: String) -> ResolvedRepoConfig {
        config.resolve(owner: owner, repo: repo)
    }

    /// The matching rule *without* defaults folded in — for the Settings
    /// UI, which needs to show whether a field is overridden or inherited.
    func rule(owner: String, repo: String) -> RepoConfig {
        config.rule(owner: owner, repo: repo)
    }

    /// Closure form for injection into `ReviewQueueWorker.configResolver`.
    /// A snapshot: a resolver handed out before an edit keeps resolving
    /// against the state it was made with — `onChange` hands out a fresh one.
    nonisolated func makeResolver() -> @Sendable (String, String) -> ResolvedRepoConfig {
        MainActor.assumeIsolated { config.resolver() }
    }

    // MARK: - edits

    /// Replace the whole config, as a front end editing its own copy does.
    func replace(with config: PRBarConfig) {
        mutate { $0 = config }
    }

    private func mutate(_ body: (inout PRBarConfig) -> Void) {
        var next = config
        body(&next)
        // A config from a front end carries no rules: they come from the
        // rules directory, which only `reloadRulesIfChanged` reads.
        next.compiledRules = config.compiledRules
        // SwiftUI writes bindings back on every edit; an unchanged value
        // must not rewrite the file or churn the resolvers.
        guard next != config else { return }
        config = next
        revision += 1
        save()
        onChange?()
    }

    // MARK: - file I/O

    private func save() {
        guard !needsConversion else {
            loadIssue = "Not saved: prbar.yaml still has `repos:`. Convert them to rules first (Settings → Rules)."
            return
        }
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
            } catch where Self.isReposMoved(error) {
                if convertRepos(), let data = try? Data(contentsOf: fileURL), (try? apply(data: data, path: fileURL.path)) != nil {
                    lastSeenData = data
                    noteConversion()
                } else {
                    loadLastGood()
                    holdUntilConverted()
                }
            } catch {
                loadIssue = "\(error.localizedDescription). Using the last config that loaded."
                PRBarLog.config.error("load failed: \(error.localizedDescription, privacy: .public)")
                loadLastGood()
            }
            return
        }
        if var migrated = legacy?() {
            if !migrated.legacyRepos.isEmpty {
                convertLegacyRepos(&migrated)
            }
            config = migrated
            migratedFromLegacy = true
            PRBarLog.config.notice("migrated legacy settings to \(self.fileURL.path, privacy: .public)")
            save()
        }
    }

    /// Writes repo rules read from the old store as the configure rule
    /// `rules convert` would, and their lists into the config.
    private func convertLegacyRepos(_ config: inout PRBarConfig) {
        let entries = config.legacyRepos
        config.legacyRepos = []
        config.repositories.hide = RulesConvert.firstMatchList(entries, default: false) { $0.excluded }
        config.repositories.trustRules = RulesConvert.firstMatchList(entries, default: false) { $0.trustRepoRules ?? false }
        let url = rulesURL.appendingPathComponent(RulesConvert.rulePath)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(RulesConvert.policy(entries, date: Date()).utf8).write(to: url, options: .atomic)
        } catch {
            PRBarLog.config.error("legacy repo rules not written: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func isReposMoved(_ error: Swift.Error) -> Bool {
        if case .reposMoved? = error as? ConfigFile.Error { return true }
        return false
    }

    /// What the last automatic conversion did, shown with the warnings.
    @ObservationIgnored private var conversion: String?

    /// Converts `repos:` into a configure rule, as `rules convert` does.
    /// False when it can't: then the store waits (`needsConversion`), with
    /// the reason, typically the repositories that would come out
    /// different, as the load issue.
    private func convertRepos() -> Bool {
        let state = lastGoodURL?.deletingLastPathComponent()
        do {
            let written = try RulesConvert.run(
                configURL: fileURL, rulesURL: rulesURL,
                repositories: state.map(RulesConvert.knownRepositories(stateDirectory:)) ?? [])
            conversion = "Converted the \(written.entries) repos: entries of prbar.yaml into \(written.rulePath), checked on \(written.checked.count) repositories; the old file is \(written.backupPath)."
            PRBarLog.config.notice("\(self.conversion ?? "", privacy: .public)")
            needsConversion = false
            return true
        } catch {
            needsConversion = true
            loadIssue = "prbar.yaml still has `repos:`, and converting them to rules didn't go through: \(error.localizedDescription)\nUntil it does, PRBar reviews nothing and posts nothing on its own."
            PRBarLog.config.error("repos: not converted: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func noteConversion() {
        reloadRulesIfChanged()
        if let conversion { warnings.insert(conversion, at: 0) }
    }

    /// Until `repos:` is converted the settings in effect aren't the ones
    /// the file asks for, so nothing runs on them: no review (which costs)
    /// and no post. In memory only; the file isn't saved meanwhile.
    private func holdUntilConverted() {
        config.defaults.aiReviewEnabled = false
        config.defaults.autoApprove.enabled = false
        config.defaults.autoDeny.action = .off
        config.defaults.shareFindings = .off
        config.defaults.resolveThreads.enabled = false
    }

    private func loadLastGood() {
        guard let lastGoodURL, let data = try? Data(contentsOf: lastGoodURL) else { return }
        if let text = String(data: data, encoding: .utf8),
           let loaded = try? ConfigFile.decode(text, path: lastGoodURL.path) {
            var next = loaded.config
            next.compiledRules = config.compiledRules
            config = next
        }
    }

    private func apply(data: Data, path: String) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConfigFile.Error.invalid(path: path, reason: "not valid UTF-8")
        }
        let loaded = try ConfigFile.decode(text, path: path)
        var next = loaded.config
        next.compiledRules = config.compiledRules
        config = next
        warnings = loaded.warnings
        loadIssue = nil
        needsConversion = false
        saveLastGood(text)
    }

    // MARK: - rules

    /// Reads the rules directory if anything in it changed. A launch whose
    /// rules don't compile runs with `Rules.unloaded`, which posts nothing;
    /// a later edit that breaks them keeps the previous ones in effect.
    /// Returns whether the rules in effect changed.
    @discardableResult
    func reloadRulesIfChanged() -> Bool {
        let seen = RuleDirectory.fingerprint(rulesURL)
        guard seen != lastSeenRules else { return false }
        let atLaunch = lastSeenRules == nil
        lastSeenRules = seen
        let next: Rules?
        do {
            next = try RuleDirectory.load(rulesURL)
            rulesIssue = nil
        } catch {
            PRBarLog.config.error("rules: \(error.localizedDescription, privacy: .public)")
            guard atLaunch else {
                rulesIssue = "\(error.localizedDescription)\nThe previous rules stay in effect."
                return false
            }
            rulesIssue = "\(error.localizedDescription)\nNothing is posted on its own until they compile."
            next = .unloaded(rulesIssue ?? "")
        }
        guard next != config.compiledRules else { return false }
        config.compiledRules = next
        return true
    }

    private func saveLastGood(_ text: String) {
        guard let lastGoodURL else { return }
        try? ConfigFile.write(text, to: lastGoodURL)
    }

    /// Re-read the file if it changed since we last read or wrote it.
    /// Called by the poller; exposed for tests.
    func reloadIfChanged() {
        if reloadRulesIfChanged() {
            revision += 1
            onChange?()
        }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard data != lastSeenData else { return }
        lastSeenData = data
        let before = config
        do {
            try apply(data: data, path: fileURL.path)
        } catch where Self.isReposMoved(error) {
            // Converted: the next pass reads the new file and the new rule.
            // Not converted: the previous config stays, with the reason.
            guard convertRepos() else { return }
            lastSeenData = nil
            reloadIfChanged()
            noteConversion()
            return
        } catch {
            loadIssue = "\(error.localizedDescription). Keeping the previous config."
            PRBarLog.config.error("reload failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        if config != before {
            revision += 1
            onChange?()
        }
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
