import Foundation

/// The app-wide default provider as the user chose it. `auto` survives
/// as a choice rather than being resolved at save time, so a config
/// written on a machine with claude installed still picks codex on a
/// runner that only has codex.
enum ProviderChoice: String, Codable, Sendable, Hashable, CaseIterable {
    case auto
    case claude
    case codex

    init(_ provider: ProviderID) {
        switch provider {
        case .claude: self = .claude
        case .codex: self = .codex
        }
    }

    func resolve(find: (String) -> Bool = { ExecutableResolver.find($0) != nil }) -> ProviderID {
        switch self {
        case .auto: return ProviderID.resolveAuto(find: find)
        case .claude: return .claude
        case .codex: return .codex
        }
    }
}

/// Which repositories PRBar handles, as glob lists (`owner/*`, `!owner/x`,
/// later patterns winning). How their PRs are reviewed is up to the
/// `configure` rules; these are the permissions above that.
struct RepositoryScope: Sendable, Hashable, Codable {
    /// Review requests PRBar triages. Nil: every repository.
    var triage: [String]?
    /// Repositories PRBar never shows.
    var hide: [String] = []
    /// Repositories whose own `.prbar/rules` are read, at their default
    /// branch. They decide what is posted under your name.
    var trustRules: [String] = []

    init(triage: [String]? = nil, hide: [String] = [], trustRules: [String] = []) {
        self.triage = triage
        self.hide = hide
        self.trustRules = trustRules
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case triage, hide, trustRules
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        triage = try c.decodeIfPresent([String].self, forKey: .triage)
        hide = try c.decodeIfPresent([String].self, forKey: .hide) ?? []
        trustRules = try c.decodeIfPresent([String].self, forKey: .trustRules) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(triage, forKey: .triage)
        if !hide.isEmpty { try c.encode(hide, forKey: .hide) }
        if !trustRules.isEmpty { try c.encode(trustRules, forKey: .trustRules) }
    }

    func triages(_ nameWithOwner: String) -> Bool {
        triage.map { GlobMatcher.anyMatch($0, nameWithOwner) } ?? true
    }

    func hides(_ nameWithOwner: String) -> Bool {
        GlobMatcher.anyMatch(hide, nameWithOwner)
    }

    func trustsRules(_ nameWithOwner: String) -> Bool {
        GlobMatcher.anyMatch(trustRules, nameWithOwner)
    }
}

/// Everything PRBar's review behaviour depends on, as one value — the
/// contents of `prbar.yaml`. The menu-bar app and the `prbar-review` CLI
/// read the same file into this type, so there is one configuration
/// format and no app-only settings that silently don't apply headless.
///
/// Machine-local preferences (badges, launch at login, the daily cost
/// cap) are deliberately not in here: they describe one user's machine,
/// not how a review should run.
struct PRBarConfig: Sendable, Hashable, Codable {
    static let currentVersion = 1

    var version: Int = PRBarConfig.currentVersion
    var defaultProvider: ProviderChoice = .auto

    /// Nil means "PRBar's compiled-in default" (`sonnet` for claude, no
    /// flag for the rest); an empty string means "pass no flag", which
    /// lets the CLI's own configured default through.
    var defaultClaudeModel: String?
    var defaultClaudeEffort: String?
    var defaultCodexModel: String?
    var defaultCodexEffort: String?

    var defaults = ReviewDefaults()
    var repositories = RepositoryScope()
    /// What coding agents may do through `prbar-review mcp`.
    var agents = AgentPolicy()
    /// The rules directory (`RuleDirectory`), compiled by whoever loaded
    /// the config (`ConfigFile.load`, `RepoConfigStore`). Kept apart from
    /// prbar.yaml: not part of the file, not sent over the API, and never
    /// rewritten by Settings.
    var compiledRules: Rules?
    /// Per-repository settings read from where they were kept before rules
    /// (the SwiftData store), to be converted into a configure rule when
    /// the file is first written. Never part of the file.
    var legacyRepos: [RepoConfig] = []

    init() {}

    enum CodingKeys: String, CodingKey, CaseIterable {
        case version, defaultProvider
        case defaultClaudeModel, defaultClaudeEffort
        case defaultCodexModel, defaultCodexEffort
        case defaults, repositories, agents
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        defaultProvider = try c.decodeIfPresent(ProviderChoice.self, forKey: .defaultProvider) ?? .auto
        defaultClaudeModel = try c.decodeIfPresent(String.self, forKey: .defaultClaudeModel)
        defaultClaudeEffort = try c.decodeIfPresent(String.self, forKey: .defaultClaudeEffort)
        defaultCodexModel = try c.decodeIfPresent(String.self, forKey: .defaultCodexModel)
        defaultCodexEffort = try c.decodeIfPresent(String.self, forKey: .defaultCodexEffort)
        defaults = try c.decodeIfPresent(ReviewDefaults.self, forKey: .defaults) ?? ReviewDefaults()
        repositories = try c.decodeIfPresent(RepositoryScope.self, forKey: .repositories) ?? RepositoryScope()
        agents = try c.decodeIfPresent(AgentPolicy.self, forKey: .agents) ?? AgentPolicy()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        if defaultProvider != .auto { try c.encode(defaultProvider, forKey: .defaultProvider) }
        try c.encodeIfPresent(defaultClaudeModel, forKey: .defaultClaudeModel)
        try c.encodeIfPresent(defaultClaudeEffort, forKey: .defaultClaudeEffort)
        try c.encodeIfPresent(defaultCodexModel, forKey: .defaultCodexModel)
        try c.encodeIfPresent(defaultCodexEffort, forKey: .defaultCodexEffort)
        if defaults != ReviewDefaults() { try c.encode(defaults, forKey: .defaults) }
        if repositories != RepositoryScope() { try c.encode(repositories, forKey: .repositories) }
        if agents != AgentPolicy() { try c.encode(agents, forKey: .agents) }
    }

    /// A repository's overrides of the review defaults: what the
    /// `configure` rules set, with the `repositories:` lists applied.
    func rule(owner: String, repo: String) -> RepoConfig {
        configured(owner: owner, repo: repo).config
    }

    func configured(owner: String, repo: String) -> Rules.Configured {
        var configured = compiledRules?.configure(owner: owner, name: repo)
            ?? Rules.Configured(config: .default, rules: [], error: nil)
        let name = "\(owner)/\(repo)"
        configured.config.excluded = repositories.hides(name)
        if repositories.trustsRules(name) { configured.config.trustRepoRules = true }
        if !repositories.triages(name) { configured.config.aiReviewEnabled = false }
        if let error = configured.error {
            PRBarLog.config.error("configure rule failed for \(name, privacy: .public): \(error, privacy: .public)")
        }
        return configured
    }

    func resolve(owner: String, repo: String) -> ResolvedRepoConfig {
        ResolvedRepoConfig(rule: rule(owner: owner, repo: repo), defaults: defaults, rules: compiledRules)
    }

    /// `resolve` as a snapshot closure, for the worker and the poller.
    /// Each repository is resolved once per snapshot: the configure rules
    /// see the repository alone, so its answer can't change until the
    /// config or the rules do, and those hand out a new resolver.
    func resolver() -> @Sendable (String, String) -> ResolvedRepoConfig {
        let config = self
        let cache = ResolutionCache()
        return { owner, repo in
            cache.value("\(owner)/\(repo)") { config.resolve(owner: owner, repo: repo) }
        }
    }

    /// Push the agent defaults into a worker. Nil fields reset to the
    /// worker's compiled-in defaults, so removing a line from the file
    /// takes effect on reload rather than leaving the old value behind.
    @MainActor
    func applyAgentDefaults(to worker: ReviewQueueWorker) {
        worker.defaultProviderId = defaultProvider.resolve()
        worker.defaultClaudeModel = defaultClaudeModel ?? ReviewQueueWorker.compiledDefaultClaudeModel
        worker.defaultClaudeEffort = defaultClaudeEffort ?? ""
        worker.defaultCodexModel = defaultCodexModel ?? ""
        worker.defaultCodexEffort = defaultCodexEffort ?? ""
    }
}

private final class ResolutionCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: ResolvedRepoConfig] = [:]

    func value(_ key: String, _ make: () -> ResolvedRepoConfig) -> ResolvedRepoConfig {
        lock.lock()
        defer { lock.unlock() }
        if let cached = values[key] { return cached }
        let made = make()
        values[key] = made
        return made
    }
}
