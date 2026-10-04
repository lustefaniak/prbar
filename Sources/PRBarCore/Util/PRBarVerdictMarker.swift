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
    ///
    /// A stamp goes after `v=1`, one `key=value` per line. Nothing reads it
    /// back: it is there for a person looking at the raw review body.
    static func emit(sha: String, stamp: VerdictStamp? = nil) -> String {
        guard let stamp else { return "\(prefix)\(sha) v=1 -->" }
        let lines = stamp.fields.map { "\($0.key)=\(sanitize($0.value))" }
        return "\(prefix)\(sha) v=1\n" + lines.joined(separator: "\n") + "\n-->"
    }

    /// Append the marker to an outgoing review body. Safe on an empty body:
    /// GitHub accepts a COMMENT review whose body is the marker alone as
    /// long as it carries inline comments, and rejects a genuinely empty
    /// one either way.
    static func append(to body: String, sha: String, stamp: VerdictStamp? = nil) -> String {
        guard !sha.isEmpty else { return body }
        if body.isEmpty { return emit(sha: sha, stamp: stamp) }
        return body + "\n\n" + emit(sha: sha, stamp: stamp)
    }

    /// A value can carry a reason or a rule id written by the user. A `--`
    /// in it would end the HTML comment early and print the rest of the
    /// stamp on the PR, and a newline would break the one-field-per-line
    /// layout.
    private static func sanitize(_ value: String) -> String {
        var s = value.replacingOccurrences(of: "\n", with: " ")
        while s.contains("--") { s = s.replacingOccurrences(of: "--", with: "-") }
        return s
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

/// Why PRBar posted what it posted, carried into the verdict marker so a
/// review on GitHub explains itself: which gate held an approval back,
/// how sure the model was, which model it was, and what had happened to
/// the threads PRBar opened earlier. Without it, debugging a teammate's
/// post means asking them to dig through their own history files.
///
/// Readable by anyone who can read the PR through the API, so it carries
/// nothing about the poster beyond the settings that shaped the post (no
/// cost, no paths).
struct VerdictStamp: Sendable, Hashable, Codable {
    /// `approve`, `request_changes`, `comment` or `share`.
    var action: String
    /// `settings`, or `rule <layer>/<id>`.
    var decidedBy: String
    /// Why the settings didn't post a verdict. Set on a share, where it is
    /// the reason the author got findings instead of an approval.
    var held: String?
    var verdict: String
    var confidence: Double
    var provider: String
    var model: String?
    var effort: String?
    /// Findings per severity, worst first: blocker, warning, suggestion, info.
    var findings: [Int]
    /// Inline comments this post carries.
    var inline: Int
    /// PRBar's threads on the PR before this review. Nil when they couldn't
    /// be read.
    var threads: ThreadFacts?
    var app: String = PRBarBuild.version

    init(
        action: String, decidedBy: String, held: String? = nil,
        review: AggregatedReview, provider: ProviderID, inline: Int, threads: ThreadFacts? = nil
    ) {
        self.action = action
        self.decidedBy = decidedBy
        self.held = held
        verdict = review.verdict.rawValue
        confidence = review.confidence
        self.provider = provider.rawValue
        findings = AnnotationSeverity.allCases.reversed().map { severity in
            review.annotations.filter { $0.severity == severity }.count
        }
        self.inline = inline
        self.threads = threads
    }

    var fields: KeyValuePairs<String, String> {
        let severities = AnnotationSeverity.allCases.reversed().map(\.rawValue)
        let counts = zip(findings, severities).map { "\($0) \($1)" }.joined(separator: ", ")
        return [
            "action": action,
            "decided_by": decidedBy,
            "held": held ?? "-",
            "verdict": verdict,
            "confidence": String(format: "%.2f", confidence),
            "provider": provider,
            "model": model ?? "default",
            "effort": effort ?? "default",
            "findings": counts,
            "inline": String(inline),
            "threads": threads.map(Self.describe) ?? "unknown",
            "app": app,
        ]
    }

    private static func describe(_ t: ThreadFacts) -> String {
        "\(t.total) total, \(t.resolved) resolved, \(t.outdated) outdated, \(t.answered) answered, "
            + "\(t.unaddressed) unaddressed, \(t.raisedAgain) raised again"
    }
}
