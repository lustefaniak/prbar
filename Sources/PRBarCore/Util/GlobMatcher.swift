import Foundation

/// fnmatch-style glob matcher used for both monorepo `repoGlob`
/// (e.g. "getsynq/*", "!getsynq/cloud") and `rootPatterns`
/// (e.g. "kernel-*", "lib/*", "dev-infra").
///
/// Supported metacharacters:
///   `*` — matches any run of characters except `/`
///   `**` — matches any run of characters including `/`
///   `?` — matches a single character (not `/`)
///   `!` — leading negation (only meaningful when matching against a list
///         of patterns; the matcher itself reports the bare result and
///         exposes `isNegation` for callers).
///
/// No bracket expressions, no brace expansion — keep it boring.
enum GlobMatcher {
    /// Match a path against a single pattern. Negation is *not* applied
    /// here; pass the stripped pattern from `Pattern.parse`.
    static func match(_ pattern: String, _ path: String) -> Bool {
        let regex = compile(pattern)
        return path.range(of: regex, options: .regularExpression) != nil
    }

    /// Pre-parsed glob pattern. Splits `!` negation from the body.
    struct Pattern: Sendable, Hashable {
        let body: String
        let isNegation: Bool

        static func parse(_ raw: String) -> Pattern {
            if raw.hasPrefix("!") {
                return Pattern(body: String(raw.dropFirst()), isNegation: true)
            }
            return Pattern(body: raw, isNegation: false)
        }

        func matches(_ path: String) -> Bool {
            GlobMatcher.match(body, path)
        }
    }

    /// Length of a pattern's "literal prefix" — used by the splitter to
    /// pick the *longest* matching root pattern (so `kernel-billing/foo`
    /// matches `kernel-*` over `*` even though both apply).
    static func specificity(_ pattern: String) -> Int {
        // Count anchored characters before the first wildcard. `lib/auth`
        // beats `lib/*` beats `*`. Ties broken by total length so deeper
        // patterns still win.
        var prefix = 0
        for ch in pattern {
            if ch == "*" || ch == "?" { break }
            prefix += 1
        }
        return prefix * 1000 + pattern.count
    }

    /// Match a path against a list of patterns; later patterns override
    /// earlier ones (gitignore-style). Used for repoGlob lists like
    /// `["getsynq/*", "!getsynq/cloud"]`.
    static func anyMatch(_ patterns: [String], _ path: String) -> Bool {
        var hit = false
        for raw in patterns {
            let p = Pattern.parse(raw)
            if p.matches(path) {
                hit = !p.isNegation
            }
        }
        return hit
    }

    // MARK: - private

    private static func compile(_ pattern: String) -> String {
        var out = "^"
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let c = pattern[i]
            switch c {
            case "*":
                let next = pattern.index(after: i)
                if next < pattern.endIndex && pattern[next] == "*" {
                    out += ".*"
                    i = pattern.index(after: next)
                    continue
                }
                out += "[^/]*"
            case "?":
                out += "[^/]"
            case ".", "(", ")", "+", "|", "^", "$", "\\", "{", "}", "[", "]":
                out += "\\\(c)"
            default:
                out.append(c)
            }
            i = pattern.index(after: i)
        }
        out += "$"
        return out
    }
}
