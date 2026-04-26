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
    /// Short headline (≤ 60 chars) — what the issue is in glanceable form.
    /// Optional in the model to stay back-compat with reviews cached
    /// before this field existed; the AI is asked to provide it.
    let title: String?
    let body: String

    /// Convenience: title if present, otherwise the first sentence of
    /// body trimmed to ~80 chars. Used by the summary list when the AI
    /// didn't supply a title (older reviews, model regression).
    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        let firstSentence = body
            .split(whereSeparator: { ".!?\n".contains($0) })
            .first
            .map(String.init) ?? body
        let trimmed = firstSentence.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 80 { return trimmed }
        return String(trimmed.prefix(80)) + "…"
    }

    init(
        path: String,
        lineStart: Int,
        lineEnd: Int,
        severity: AnnotationSeverity,
        title: String? = nil,
        body: String
    ) {
        self.path = path
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.severity = severity
        self.title = title
        self.body = body
    }

    enum CodingKeys: String, CodingKey {
        case path
        case lineStart = "line_start"
        case lineEnd = "line_end"
        case severity
        case title
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
