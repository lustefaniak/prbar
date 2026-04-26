import Foundation

/// Which AI CLI runs the review. Pluggable via the `ReviewProvider`
/// protocol; resolution priority is per-run override (set from
/// PRDetailView "Re-run with…") > per-repo `RepoConfig.providerOverride`
/// > app-wide default (UserDefaults `defaultProviderId`, default
/// `.claude`).
enum ProviderID: String, Codable, Sendable, Hashable, CaseIterable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        }
    }

    /// CLI binary name resolved via `ExecutableResolver.find(_:)`.
    var binaryName: String {
        switch self {
        case .claude: return "claude"
        case .codex:  return "codex"
        }
    }

    /// "Auto" tag for the General Settings picker — stored in
    /// UserDefaults under `defaultProviderId` instead of a real
    /// `ProviderID.rawValue`. Resolved at app launch to a concrete
    /// provider via `resolveAuto()`.
    static let autoSentinel = "auto"

    /// Pick the best available provider. Tie-break is **claude** when
    /// both are installed (more battle-tested in PRBar; live streaming
    /// + SIGTERM-on-budget; subscription auth = $0 cost). When neither
    /// is installed we still default to claude — the failure surfaces
    /// later with a clear "not found" error, which is more honest than
    /// silently swapping to a backend the user also doesn't have.
    static func resolveAuto(
        find: (String) -> Bool = { ExecutableResolver.find($0) != nil }
    ) -> ProviderID {
        let claudeOK = find("claude")
        let codexOK  = find("codex")
        if claudeOK { return .claude }
        if codexOK  { return .codex }
        return .claude
    }
}

enum PRRole: String, Codable, Sendable, Hashable, CaseIterable {
    case authored
    case reviewRequested
    case both
    case other
}

enum ReviewActionKind: String, Codable, Sendable, Hashable, CaseIterable {
    case approve
    case comment
    case requestChanges = "request_changes"

    var ghFlag: String {
        switch self {
        case .approve:        return "--approve"
        case .comment:        return "--comment"
        case .requestChanges: return "--request-changes"
        }
    }

    var displayName: String {
        switch self {
        case .approve:        return "Approve"
        case .comment:        return "Comment"
        case .requestChanges: return "Request changes"
        }
    }

    var actionLogKind: ActionLogKind {
        switch self {
        case .approve:        return .approve
        case .comment:        return .comment
        case .requestChanges: return .requestChanges
        }
    }
}

enum MergeMethod: String, Codable, Sendable, Hashable, CaseIterable {
    case squash
    case merge
    case rebase

    var ghFlag: String {
        switch self {
        case .squash: return "--squash"
        case .merge: return "--merge"
        case .rebase: return "--rebase"
        }
    }

    var displayName: String {
        switch self {
        case .squash: return "Squash and merge"
        case .merge:  return "Create a merge commit"
        case .rebase: return "Rebase and merge"
        }
    }

    /// Tight label for the row's split-button primary action.
    var shortDisplayName: String {
        switch self {
        case .squash: return "Squash"
        case .merge:  return "Merge"
        case .rebase: return "Rebase"
        }
    }
}
