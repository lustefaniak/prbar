import Foundation

/// Parses unified-diff output (the kind `gh pr diff` and `git diff` produce)
/// into a flat list of hunks tagged with their file path. Tolerant of:
///   - rename headers (`rename from` / `rename to`) — picks the new name.
///   - mode changes / index lines — ignored.
///   - binary files (`Binary files X and Y differ`) — skipped silently.
///   - missing trailing newlines (`\ No newline at end of file`) — skipped.
/// Lines starting with `\` (no-newline marker) and any prelude that doesn't
/// belong to a hunk are dropped.
enum DiffParser {
    static func parse(_ text: String) -> [Hunk] {
        var hunks: [Hunk] = []

        var currentFile: String?
        var currentHunk: HunkInProgress?

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        func flushHunk() {
            if let h = currentHunk, let f = currentFile {
                hunks.append(Hunk(
                    filePath: f,
                    oldStart: h.oldStart, oldCount: h.oldCount,
                    newStart: h.newStart, newCount: h.newCount,
                    lines: h.lines
                ))
            }
            currentHunk = nil
        }

        for line in lines {
            // File header — diff --git a/<path> b/<path>
            if line.hasPrefix("diff --git ") {
                flushHunk()
                currentFile = parseGitDiffPath(line)
                continue
            }

            // Rename: prefer the new name when we see "rename to <path>".
            if line.hasPrefix("rename to ") {
                currentFile = String(line.dropFirst("rename to ".count))
                continue
            }

            // +++ b/<path> — also gives us the new path; useful when there's
            // no `diff --git` prefix (rare but happens in patch files).
            if line.hasPrefix("+++ ") {
                let path = parseTripleHeader(line)
                if currentFile == nil { currentFile = path }
                continue
            }

            // --- a/<path> — old path, ignored unless we have nothing else.
            if line.hasPrefix("--- ") {
                continue
            }

            // Hunk header: @@ -<oldStart>,<oldCount> +<newStart>,<newCount> @@ ...
            if line.hasPrefix("@@") {
                flushHunk()
                if let parsed = parseHunkHeader(line) {
                    currentHunk = HunkInProgress(
                        oldStart: parsed.oldStart,
                        oldCount: parsed.oldCount,
                        newStart: parsed.newStart,
                        newCount: parsed.newCount,
                        lines: []
                    )
                }
                continue
            }

            // Binary, no-newline marker, mode change — skip.
            if line.hasPrefix("Binary files ") ||
               line.hasPrefix("\\ ") ||
               line.hasPrefix("index ") ||
               line.hasPrefix("similarity ") ||
               line.hasPrefix("dissimilarity ") ||
               line.hasPrefix("new file mode ") ||
               line.hasPrefix("deleted file mode ") ||
               line.hasPrefix("old mode ") ||
               line.hasPrefix("new mode ") {
                continue
            }

            // Hunk body line.
            if currentHunk != nil {
                if line.hasPrefix("+") {
                    currentHunk?.lines.append(.added(String(line.dropFirst())))
                } else if line.hasPrefix("-") {
                    currentHunk?.lines.append(.removed(String(line.dropFirst())))
                } else if line.hasPrefix(" ") || line.isEmpty {
                    // Empty line in a hunk represents an empty context line.
                    currentHunk?.lines.append(.context(line.isEmpty ? "" : String(line.dropFirst())))
                }
                // Anything else (e.g. stray text) — ignore.
            }
        }

        flushHunk()
        return hunks
    }

    // MARK: - parsers

    private struct HunkInProgress {
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
        var lines: [DiffLine]
    }

    /// Extracts the new path from `diff --git a/<path> b/<path>`. Falls back
    /// to whatever string follows `b/` if the prefix isn't there (e.g.
    /// quoted-path edge cases).
    private static func parseGitDiffPath(_ line: String) -> String? {
        // Format: "diff --git a/foo/bar.go b/foo/bar.go"
        // Use the b/ side since renames keep the "to" path there.
        guard let bRange = line.range(of: " b/") else { return nil }
        return String(line[bRange.upperBound...])
    }

    /// Extracts the path from `+++ b/<path>` or `--- a/<path>`. Strips the
    /// `b/` or `a/` prefix that git adds.
    private static func parseTripleHeader(_ line: String) -> String? {
        // Format: "+++ b/<path>" or "+++ /dev/null"
        let body = line.dropFirst(4)
        if body == "/dev/null" { return nil }
        if body.hasPrefix("a/") || body.hasPrefix("b/") {
            return String(body.dropFirst(2))
        }
        return String(body)
    }

    /// Parses `@@ -a,b +c,d @@ optional-context-text` into the four counts.
    /// Single-line ranges may omit the count: `@@ -42 +45 @@`.
    private static func parseHunkHeader(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        // Strip leading "@@ " and trailing " @@..." plus everything after.
        guard line.hasPrefix("@@") else { return nil }
        let withoutPrefix = line.dropFirst(2).drop(while: { $0 == " " })
        guard let endRange = withoutPrefix.range(of: "@@") else { return nil }
        let core = withoutPrefix[..<endRange.lowerBound].trimmingCharacters(in: .whitespaces)
        // core should now be "-a,b +c,d"
        let parts = core.split(separator: " ").map(String.init)
        guard parts.count == 2 else { return nil }
        guard let oldRange = parseRange(parts[0]), parts[0].hasPrefix("-") else { return nil }
        guard let newRange = parseRange(parts[1]), parts[1].hasPrefix("+") else { return nil }
        return (oldRange.start, oldRange.count, newRange.start, newRange.count)
    }

    /// Parses "-42,7" or "-42" or "+5" → (start, count). Default count is 1
    /// when omitted (per the unified-diff spec).
    private static func parseRange(_ s: String) -> (start: Int, count: Int)? {
        let body = String(s.dropFirst())
        let parts = body.split(separator: ",", maxSplits: 1).map(String.init)
        guard let start = Int(parts[0]) else { return nil }
        let count = parts.count == 2 ? Int(parts[1]) : 1
        guard let c = count else { return nil }
        return (start, c)
    }
}
