import Foundation

/// Pure function: maps AI annotations onto GitHub inline review comments,
/// dropping any that don't land on a line GitHub will accept.
///
/// GitHub rejects a `comments[]` entry whose `line` isn't an added or
/// context line on the new side of the PR's diff, and rejects a multi-line
/// span unless `start_line < line`. Filtering here (rather than letting the
/// API 422) is what lets both the manual post path and the auto-review path
/// show an honest "N comments will be posted" count.
enum InlineCommentMapper {
    /// Appended to every inline comment PRBar posts, and required by
    /// `ReviewThreadResolver` before it will resolve a thread.
    ///
    /// A login check alone can't prove PRBar wrote a comment — it only
    /// proves the authenticated user did, which is equally true of every
    /// review comment they hand-typed on github.com. Resolving collapses
    /// the thread for everyone on the PR, so "did we write this?" has to
    /// be answerable from the comment itself. An HTML comment renders as
    /// nothing in GitHub's markdown and survives the round-trip verbatim.
    ///
    /// Threads posted before this marker existed will never resolve. That
    /// is the safe direction: they stay open, exactly as they do today.
    static let provenanceMarker = "<!-- prbar:finding -->"

    static func map(
        annotations: [DiffAnnotation],
        hunks: [Hunk]
    ) -> [GHClient.InlineComment] {
        // Build per-path map of valid new-file line numbers.
        var validByPath: [String: Set<Int>] = [:]
        for h in hunks {
            var newLine = h.newStart
            var valid: Set<Int> = []
            for line in h.lines {
                switch line {
                case .added, .context:
                    valid.insert(newLine)
                    newLine += 1
                case .removed:
                    break
                }
            }
            validByPath[h.filePath, default: []].formUnion(valid)
        }
        return annotations.compactMap { ann in
            guard let valid = validByPath[ann.path] else { return nil }
            guard valid.contains(ann.lineEnd) else { return nil }
            let startLine = ann.lineStart < ann.lineEnd && valid.contains(ann.lineStart)
                ? ann.lineStart : nil
            let header: String = {
                if let t = ann.title, !t.isEmpty { return "**\(t)**\n\n" }
                return ""
            }()
            return GHClient.InlineComment(
                path: ann.path,
                line: ann.lineEnd,
                startLine: startLine,
                body: header + ann.body + "\n\n" + Self.provenanceMarker
            )
        }
    }
}
