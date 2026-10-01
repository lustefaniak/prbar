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
    var repos: [RepoConfig] = []
    /// What coding agents may do through `prbar-review mcp`.
    var agents = AgentPolicy()

    init() {}

    enum CodingKeys: String, CodingKey, CaseIterable {
        case version, defaultProvider
        case defaultClaudeModel, defaultClaudeEffort
        case defaultCodexModel, defaultCodexEffort
        case defaults, repos, agents
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
        repos = try c.decodeIfPresent([RepoConfig].self, forKey: .repos) ?? []
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
        if !repos.isEmpty { try c.encode(repos, forKey: .repos) }
        if agents != AgentPolicy() { try c.encode(agents, forKey: .agents) }
    }

    /// First matching repo rule wins, then `RepoConfig.match` supplies the
    /// built-in fallback; unset fields resolve from `defaults`.
    func resolver() -> @Sendable (String, String) -> ResolvedRepoConfig {
        let repos = self.repos
        let defaults = self.defaults
        return { owner, repo in
            let nameWithOwner = "\(owner)/\(repo)"
            if let rule = repos.first(where: { $0.matches(nameWithOwner: nameWithOwner) }) {
                return rule.resolved(with: defaults)
            }
            return RepoConfig.match(owner: owner, repo: repo).resolved(with: defaults)
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
