import Foundation

/// Helpers shared between `FailureLogStore` (UI) and `ReviewQueueWorker`
/// (prompt context) for turning a failed `CheckSummary` into a tailed
/// log snippet the AI and the user can both consume.
enum CIFailureLogTail {
    /// Number of trailing lines kept from each job log. Tuned for the
    /// AI prompt budget: ~200 lines × ~100 chars ≈ 20 KB per failed
    /// job, well under the inbox-110KB ProcessRunner ceiling.
    static let defaultTailLines: Int = 200

    /// Extract the Actions job ID from a CheckRun's `detailsUrl`.
    /// Format observed in the wild:
    ///   `https://github.com/owner/repo/actions/runs/<runId>/job/<jobId>`
    /// The id is the last `job/<digits>` path component.
    /// StatusContext URLs (legacy CI, Vercel, etc.) don't follow this
    /// shape and return nil — those checks won't get logs.
    static func parseJobId(from urlString: String?) -> Int64? {
        guard let urlString,
              let url = URL(string: urlString) else { return nil }
        let parts = url.pathComponents
        guard let idx = parts.lastIndex(of: "job"),
              idx + 1 < parts.count else { return nil }
        return Int64(parts[idx + 1])
    }

    /// Strip GitHub Actions log timestamps (`2024-01-02T03:04:05.6789Z `
    /// prefix on every line) and tail to the last `n` lines. Keeps the
    /// section human-readable in the UI and shrinks the prompt payload.
    static func tail(_ raw: String, lines n: Int = defaultTailLines) -> String {
        let stripped = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { stripTimestamp(String($0)) }
        let kept = stripped.suffix(n)
        return kept.joined(separator: "\n")
    }

    /// Lines look like `2024-05-01T12:34:56.7890123Z actual content`.
    /// Drop the timestamp + single space if present; otherwise pass
    /// through unchanged.
    private static func stripTimestamp(_ line: String) -> String {
        // Quickest possible check: ISO-8601 always has the literal 'T'
        // at index 10 and 'Z' somewhere before the first space.
        guard line.count > 28 else { return line }
        let chars = Array(line)
        guard chars[4] == "-", chars[7] == "-", chars[10] == "T" else { return line }
        guard let zIdx = chars.firstIndex(of: "Z"), zIdx < chars.count - 1, chars[zIdx + 1] == " " else {
            return line
        }
        return String(chars[(zIdx + 2)...])
    }
}
