import Foundation

/// Machine-readable stamp PRBar embeds in every review it posts on its own
/// initiative, so a second reviewer's PRBar can tell the diff has already
/// been triaged and skip its own run.
///
/// Several reviewers requested on one PR each poll the same PR and each
/// spawn their own AI review of the same diff — duplicate cost, duplicate
/// verdicts. There is no shared backend to coordinate through (and adding
/// one would cost the "no OAuth, no API keys, no backend" property the app
/// is built around), so the PR itself is the channel: the marker is written
/// by whichever instance posts first and read by all the others out of the
/// review bodies the inbox poll already fetches.
///
/// Keyed on the head SHA because that is exactly the scope of a review's
/// validity. A new push moves the SHA, no marker matches, and every
/// instance correctly re-triages.
///
/// Renders as nothing in GitHub's markdown, and survives the API
/// round-trip verbatim — the same properties that make
/// `InlineCommentMapper.provenanceMarker` work.
enum PRBarVerdictMarker {
    private static let prefix = "<!-- prbar:verdict sha="

    /// The marker for one commit. `v` is the marker's own format version,
    /// so a future field can be added without older instances mis-reading
    /// it — matching ignores everything after the SHA.
    static func emit(sha: String) -> String {
        "\(prefix)\(sha) v=1 -->"
    }

    /// Append the marker to an outgoing review body. Safe on an empty body:
    /// GitHub accepts a COMMENT review whose body is the marker alone as
    /// long as it carries inline comments, and rejects a genuinely empty
    /// one either way.
    static func append(to body: String, sha: String) -> String {
        guard !sha.isEmpty else { return body }
        if body.isEmpty { return emit(sha: sha) }
        return body + "\n\n" + emit(sha: sha)
    }

    /// True when `body` carries a marker for this exact commit. Matches on
    /// the prefix up to and including the SHA rather than the whole marker,
    /// so an instance running a newer marker version still dedups against
    /// an older one.
    static func matches(sha: String, in body: String) -> Bool {
        guard !sha.isEmpty else { return false }
        return body.contains("\(prefix)\(sha) ")
    }

    /// Strip every marker (any SHA, any version) out of a body for display.
    ///
    /// Load-bearing, not cosmetic: `InboxPR` drops body-less COMMENT
    /// reviews from `humanReviews` so GitHub's empty review wrappers don't
    /// render as noise, and a share whose findings all landed inline posts
    /// exactly that — an empty body. Leaving the marker in would make those
    /// reviews non-empty and surface them as blank rows in the activity
    /// timeline.
    static func strip(from body: String) -> String {
        guard let start = body.range(of: prefix) else { return body }
        guard let end = body.range(of: "-->", range: start.upperBound..<body.endIndex) else {
            return body
        }
        let stripped = body.replacingCharacters(in: start.lowerBound..<end.upperBound, with: "")
        // Recurse rather than loop: a body carrying two markers is already
        // odd, and this keeps the single-marker path (every real body) at
        // one pass.
        return strip(from: stripped).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
