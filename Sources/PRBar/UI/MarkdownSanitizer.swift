import Foundation

/// Cleans GitHub/Linear-flavored Markdown of raw HTML noise before it
/// reaches `swift-markdown-ui`, which otherwise renders HTML comments and
/// stray tags as literal text. We deliberately do NOT render HTML — the
/// goal is to strip the cruft (sticky-comment bot markers like
/// `<!-- Sticky Pull Request Comment ... -->`, Linear's `<p>`/`<sub>`
/// wrappers) while preserving the human-readable content.
///
/// Code is protected: fenced blocks and inline spans are stashed before
/// stripping and restored afterward, so a comment that legitimately shows
/// `<div>` or `<!-- ... -->` inside backticks survives intact.
enum MarkdownSanitizer {
    static func sanitize(_ raw: String) -> String {
        var text = raw
        var stash: [String] = []

        // Protect code first (fenced, then inline) so HTML stripping never
        // touches markup the author meant to display literally.
        text = protectMatches(in: text, pattern: "(?s)```.*?```|~~~.*?~~~", stash: &stash)
        text = protectMatches(in: text, pattern: "`[^`\\n]+`", stash: &stash)

        // HTML comments — bot markers and hidden metadata. Multi-line.
        text = replace(text, pattern: "(?s)<!--.*?-->", with: "")
        // <a href="URL">TEXT</a> → [TEXT](URL). Preserves links (Linear
        // linkbacks, inline references) that the generic tag strip below
        // would otherwise flatten to bare text.
        text = replaceTemplate(
            text,
            pattern: "(?is)<a\\s[^>]*href=\"([^\"]*)\"[^>]*>(.*?)</a>",
            template: "[$2]($1)"
        )
        // <br> in any spelling → a real line break.
        text = replace(text, pattern: "(?i)<br\\s*/?>", with: "\n")
        // Remaining raw tags: drop the tag, keep inner text. The tag-name
        // anchor (a letter, then word chars, then optional attrs) means a
        // GFM autolink like <https://example.com> or <a@b.com> is left
        // alone — its first char after `<` is followed by `:`/`@`, not a
        // valid tag continuation.
        text = replace(text, pattern: "</?[a-zA-Z][a-zA-Z0-9]*(?:\\s[^>]*)?/?>", with: "")

        // Comment/tag removal can leave runs of blank lines — collapse them.
        text = replace(text, pattern: "\\n{3,}", with: "\n\n")

        for (i, original) in stash.enumerated() {
            text = text.replacingOccurrences(of: placeholder(i), with: original)
        }
        return text
    }

    private static func placeholder(_ i: Int) -> String { "\u{0}PRBAR_CODE_\(i)\u{0}" }

    private static func protectMatches(in text: String, pattern: String, stash: inout [String]) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            result += placeholder(stash.count)
            stash.append(ns.substring(with: m.range))
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    private static func replace(_ text: String, pattern: String, with repl: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        return re.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: NSRegularExpression.escapedTemplate(for: repl)
        )
    }

    /// Like `replace`, but the template is passed through verbatim so
    /// `$1`/`$2` capture-group references work (used for `<a>` → link).
    private static func replaceTemplate(_ text: String, pattern: String, template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        return re.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: template
        )
    }
}
