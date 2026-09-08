import Foundation

/// The CLI's stand-in for `RepoConfigStore`: the same two-level
/// `ReviewDefaults` ← `RepoConfig` chain, read from one JSON file instead
/// of SwiftData + UserDefaults. Every field is optional so a config can
/// be as small as `{}`.
///
/// Note what the shipped defaults mean here: auto-approve, auto-deny and
/// share-findings are all off, so an unconfigured run reviews the PR and
/// posts nothing. That is the safe default, not a broken one — turn on at
/// least `shareFindings` to get anything onto the PR.
struct CLIConfig: Decodable {
    var defaults: ReviewDefaults = ReviewDefaults()
    var repos: [RepoConfig] = []
    var defaultProvider: ProviderID = .claude
    var defaultClaudeModel: String?
    var defaultClaudeEffort: String?
    var defaultCodexModel: String?
    var defaultCodexEffort: String?

    enum CodingKeys: String, CodingKey {
        case defaults, repos, defaultProvider
        case defaultClaudeModel, defaultClaudeEffort
        case defaultCodexModel, defaultCodexEffort
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaults = try c.decodeIfPresent(ReviewDefaults.self, forKey: .defaults) ?? ReviewDefaults()
        repos = try c.decodeIfPresent([RepoConfig].self, forKey: .repos) ?? []
        defaultProvider = try c.decodeIfPresent(ProviderID.self, forKey: .defaultProvider) ?? .claude
        defaultClaudeModel = try c.decodeIfPresent(String.self, forKey: .defaultClaudeModel)
        defaultClaudeEffort = try c.decodeIfPresent(String.self, forKey: .defaultClaudeEffort)
        defaultCodexModel = try c.decodeIfPresent(String.self, forKey: .defaultCodexModel)
        defaultCodexEffort = try c.decodeIfPresent(String.self, forKey: .defaultCodexEffort)
    }

    /// `--config`, else `$PRBAR_CONFIG`, else `./prbar.json` when it
    /// exists. No file at all is a valid configuration.
    static func load(path explicit: String?) throws -> CLIConfig {
        let env = ProcessInfo.processInfo.environment["PRBAR_CONFIG"]
        let candidate = explicit ?? env ?? "prbar.json"
        let required = explicit != nil || env != nil
        guard FileManager.default.fileExists(atPath: candidate) else {
            if required {
                throw CLIError.configUnreadable(candidate, "no such file")
            }
            return CLIConfig()
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: candidate))
            return try JSONDecoder().decode(CLIConfig.self, from: data)
        } catch {
            throw CLIError.configUnreadable(candidate, error.localizedDescription)
        }
    }

    /// Mirrors `RepoConfigStore.makeResolver` — a user rule wins over the
    /// built-ins, and `RepoConfig.match` supplies the fallback.
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
}

enum CLIError: LocalizedError {
    case configUnreadable(String, String)

    var errorDescription: String? {
        switch self {
        case let .configUnreadable(path, reason):
            return "cannot read config \(path): \(reason)"
        }
    }
}
