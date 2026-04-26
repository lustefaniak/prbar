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
