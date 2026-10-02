import Foundation

/// Colouring for a rule file: YAML keys and comments, and inside the CEL
/// the facts, functions, strings, numbers and keywords. Spans are UTF-16
/// ranges, as NSTextView counts.
enum RuleHighlighter {
    enum Kind: Sendable, Hashable {
        case comment, key, string, number, keyword, fact, function, punctuation
    }

    struct Span: Hashable, Sendable {
        var location: Int
        var length: Int
        var kind: Kind
    }

    static let roots: Set<String> = ["pr", "review", "below", "repo", "lists", "severity", "viewer", "now", "trigger", "variables"]
    static let keywords: Set<String> = ["true", "false", "null", "in", "&&", "||", "!", "?", ":"]

    static func spans(_ text: String) -> [Span] {
        var spans: [Span] = []
        var offset = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let units = Array(String(line).utf16)
            spans += lineSpans(units, base: offset)
            offset += units.count + 1
        }
        return spans
    }

    private static func lineSpans(_ u: [UInt16], base: Int) -> [Span] {
        var spans: [Span] = []
        var i = 0
        func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 }
        while i < u.count, isSpace(u[i]) { i += 1 }
        if i < u.count, u[i] == 35 {  // #
            return [Span(location: base + i, length: u.count - i, kind: .comment)]
        }
        if i + 1 < u.count, u[i] == 45, isSpace(u[i + 1]) {  // "- "
            spans.append(Span(location: base + i, length: 1, kind: .punctuation))
            i += 2
            while i < u.count, isSpace(u[i]) { i += 1 }
        }
        // A YAML key: a plain word up to ": " or a line-ending colon.
        var j = i
        while j < u.count, isWordUnit(u[j]) { j += 1 }
        if j > i, j < u.count, u[j] == 58, j + 1 == u.count || isSpace(u[j + 1]) {
            spans.append(Span(location: base + i, length: j - i, kind: .key))
            i = j + 1
        }
        spans += valueSpans(u, from: i, base: base)
        return spans
    }

    /// The value part: CEL or plain YAML, coloured the same way, which
    /// reads right for both.
    private static func valueSpans(_ u: [UInt16], from start: Int, base: Int) -> [Span] {
        var spans: [Span] = []
        var i = start
        while i < u.count {
            let c = u[i]
            if c == 34 || c == 39 {  // " or '
                var j = i + 1
                while j < u.count, u[j] != c { j += (u[j] == 92 ? 2 : 1) }
                let end = min(u.count, j + 1)
                // A single-quoted YAML scalar wrapping a whole condition is
                // CEL inside, not a string: colour what's in it.
                if c == 39, i == firstNonSpace(u, from: start) {
                    spans += valueSpans(Array(u[(i + 1)..<max(i + 1, min(j, u.count))]), from: 0, base: base + i + 1)
                } else {
                    spans.append(Span(location: base + i, length: end - i, kind: .string))
                }
                i = end
                continue
            }
            if c == 35, i > 0, u[i - 1] == 32 {  // " #" comment
                spans.append(Span(location: base + i, length: u.count - i, kind: .comment))
                break
            }
            if isDigit(c) {
                var j = i
                while j < u.count, isDigit(u[j]) || u[j] == 46 { j += 1 }
                spans.append(Span(location: base + i, length: j - i, kind: .number))
                i = j
                continue
            }
            if isIdentStart(c) {
                var j = i
                while j < u.count, isWordUnit(u[j]) || u[j] == 46 { j += 1 }
                let word = String(decoding: u[i..<j], as: UTF16.self)
                let root = String(word.split(separator: ".").first ?? "")
                let calls = j < u.count && u[j] == 40
                if keywords.contains(word) {
                    spans.append(Span(location: base + i, length: j - i, kind: .keyword))
                } else if roots.contains(root) {
                    spans.append(Span(location: base + i, length: j - i, kind: .fact))
                } else if calls {
                    spans.append(Span(location: base + i, length: j - i, kind: .function))
                }
                i = j
                continue
            }
            if c == 38 || c == 124, i + 1 < u.count, u[i + 1] == c {  // && ||
                spans.append(Span(location: base + i, length: 2, kind: .keyword))
                i += 2
                continue
            }
            i += 1
        }
        return spans
    }

    private static func firstNonSpace(_ u: [UInt16], from start: Int) -> Int {
        var i = start
        while i < u.count, u[i] == 32 { i += 1 }
        return i
    }

    private static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    private static func isIdentStart(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 }
    private static func isWordUnit(_ c: UInt16) -> Bool { isIdentStart(c) || isDigit(c) || c == 45 }
}
