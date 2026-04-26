import Foundation

enum ReviewVerdict: String, Codable, Sendable, Hashable, CaseIterable {
    case approve
    case comment
    case requestChanges = "request_changes"
    case abstain

    var displayName: String {
        switch self {
        case .approve:        return "Approve"
        case .comment:        return "Comment"
        case .requestChanges: return "Request changes"
        case .abstain:        return "Abstain"
        }
    }

    /// Ordering for worst-verdict aggregation across subreviews. Higher
    /// number = worse outcome. `request_changes` wins over `comment` wins
    /// over `approve` wins over `abstain`.
    var severityRank: Int {
        switch self {
        case .abstain:        return 0
        case .approve:        return 1
        case .comment:        return 2
        case .requestChanges: return 3
        }
    }
}

enum AnnotationSeverity: String, Codable, Sendable, Hashable, CaseIterable {
    case info
    case suggestion
    case warning
    case blocker

    /// Whether an annotation at this severity blocks auto-approval.
    var isBlocking: Bool {
        switch self {
        case .info, .suggestion: return false
        case .warning, .blocker: return true
        }
    }
}

enum ToolMode: String, Codable, Sendable, Hashable, CaseIterable {
    /// Default. Read/Glob/Grep + WebFetch/WebSearch + per-subfolder MCP
    /// tools. `--permission-mode plan` blocks any state mutation.
    case minimal

    /// Opt-in. No tools at all. Useful for repos where filesystem access
    /// is undesirable (e.g. paranoid mode, repos not yet cloned locally).
    case none
}

struct DiffAnnotation: Codable, Sendable, Hashable {
    let path: String
    let lineStart: Int
    let lineEnd: Int
    let severity: AnnotationSeverity
    let body: String

    enum CodingKeys: String, CodingKey {
        case path
        case lineStart = "line_start"
        case lineEnd = "line_end"
        case severity
        case body
    }
}

/// Available status of a `ReviewProvider` (the AI CLI it wraps).
enum ProviderAvailability: Sendable, Hashable {
    case ready
    case notInstalled
    case notLoggedIn(reason: String)
    case otherError(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}
