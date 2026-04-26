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

    /// Hard cap for `displayTitle` length, regardless of what the AI
    /// emits. The schema can't enforce `maxLength` (claude's
    /// `--json-schema` rejects it — see PLAN.md gotchas) so we trim
    /// client-side as a safety net. The full title stays in `title` on
    /// the underlying model; only the rendered string is truncated.
    static let titleHardCap = 80

    /// Convenience: title if present, otherwise the first sentence of
    /// body trimmed. Strips markdown noise (backticks, leading **bold**,
    /// trailing punctuation) the prompt explicitly forbids — but
    /// occasional models still slip in.
    var displayTitle: String {
        let raw: String
        if let t = title, !t.isEmpty {
            raw = t
        } else {
            raw = body
                .split(whereSeparator: { ".!?\n".contains($0) })
                .first
                .map(String.init) ?? body
        }
        return Self.normalizeTitle(raw)
    }

    static func normalizeTitle(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip backticks (the prompt forbids them in titles, but
        // claude/codex sometimes wrap identifiers anyway).
        s = s.replacingOccurrences(of: "`", with: "")
        // Drop leading **Bold** markers — and the colon/dash that
        // commonly follows them, since `**Bug**: cache miss` is
        // really just "cache miss" with throat-clearing.
        if s.hasPrefix("**") {
            s = String(s.dropFirst(2))
            if let end = s.range(of: "**") {
                let after = s.index(end.upperBound, offsetBy: 0)
                s = String(s[..<end.lowerBound]) + String(s[after...])
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            // If the bolded word was a tag like "Bug" / "Note", a
            // trailing ":" or "-" usually follows. Strip + the bold
            // word + that separator.
            if let colon = s.firstIndex(where: { $0 == ":" || $0 == "-" || $0 == "—" }) {
                let before = s[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
                if !before.isEmpty && before.allSatisfy({ $0.isLetter || $0 == " " }) && before.count <= 20 {
                    s = String(s[s.index(after: colon)...])
                }
            }
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop trailing terminator punctuation — the prompt asks for
        // none. Keeps "?" off the end of e.g. "Why catch and rethrow?".
        while let last = s.last, [".", "!", ",", ";", ":"].contains(last) {
            s.removeLast()
        }
        if s.count <= titleHardCap { return s }
        // Truncate on a word boundary when one is reachable in the last
        // 20 chars; otherwise hard-cut.
        let cut = s.prefix(titleHardCap)
        if let space = cut.lastIndex(of: " "),
           cut.distance(from: space, to: cut.endIndex) <= 20 {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
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
