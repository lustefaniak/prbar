import Foundation

/// Salvages a usable review from claude's `StructuredOutput` tool output.
///
/// Background: `claude -p --json-schema` emits the final answer through a
/// synthetic `StructuredOutput` tool. When the `summary` is a long
/// markdown string, the CLI's tool-argument serialization breaks — it
/// slips into the `<parameter name="...">` invoke syntax mid-value, so the
/// closing `</summary>` and the start of the `annotations` parameter leak
/// *inside* the `summary` string. The parsed input then has no top-level
/// `annotations` key. Historically the schema marked `annotations`
/// required, so this tripped a "must have required property 'annotations'"
/// rejection loop; after a few retries the model gave up and submitted a
/// placeholder like `{"summary":"test"}`, which became the stored review.
///
/// Two defenses live here, both independent of the schema change that
/// made `annotations` optional:
///  1. `sanitizeSummary` strips the leaked `</summary>` / `<parameter>`
///     tail so a recovered summary reads cleanly.
///  2. `best` prefers the CLI's final answer but falls back to the richest
///     earlier attempt when the final one is a degenerate placeholder —
///     so even a fresh recurrence of the serialization bug can't discard a
///     substantive review that's sitting in the stream.
enum StructuredOutputRecovery {
    /// A summary this short from an AI code review is almost certainly a
    /// placeholder the model emitted to escape a rejection loop ("test",
    /// "Test summary.", "N/A"), not a real verdict. We only ever *override*
    /// with an earlier attempt when the final summary is below this and a
    /// clearly richer attempt exists, so a genuinely terse-but-real summary
    /// is never replaced by a longer rejected draft.
    static let degenerateSummaryMaxLength = 40

    /// Markers the model leaks when its tool arguments switch to the
    /// `<parameter>` XML syntax. Everything from the first marker onward is
    /// serialization noise, never review prose.
    private static let leakMarkers = ["</summary>", "\n<parameter name=\""]

    static func isDegenerate(_ summary: String) -> Bool {
        summary.trimmingCharacters(in: .whitespacesAndNewlines).count < degenerateSummaryMaxLength
    }

    /// Trim the summary at the first leaked-tool-syntax marker.
    static func sanitizeSummary(_ raw: String) -> String {
        var cut = raw.endIndex
        for marker in leakMarkers {
            if let r = raw.range(of: marker), r.lowerBound < cut {
                cut = r.lowerBound
            }
        }
        return String(raw[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// When the `annotations` parameter leaked into the summary tail, the
    /// JSON array often survives verbatim after
    /// `<parameter name="annotations">`. Best-effort parse it back so a
    /// recovered review keeps its inline comments.
    static func recoverAnnotations(fromLeakedSummary raw: String) -> [DiffAnnotation] {
        guard let marker = raw.range(of: "<parameter name=\"annotations\">") else { return [] }
        let tail = raw[marker.upperBound...]
        guard let start = tail.firstIndex(of: "["),
              let end = tail.lastIndex(of: "]")
        else { return [] }
        let slice = tail[start...end]
        guard let data = String(slice).data(using: .utf8),
              let anns = try? JSONDecoder().decode([DiffAnnotation].self, from: data)
        else { return [] }
        return anns
    }

    /// Decode one candidate payload (the final `structured_output`, or a
    /// captured `StructuredOutput` attempt), applying sanitization and
    /// annotation recovery. Returns nil if it can't yield at least a
    /// verdict + summary.
    static func decodeLenient(_ data: Data) -> ProviderStructuredOutput? {
        guard let base = try? JSONDecoder().decode(ProviderStructuredOutput.self, from: data) else {
            return nil
        }
        let clean = sanitizeSummary(base.summary)
        let annotations = base.annotations.isEmpty
            ? recoverAnnotations(fromLeakedSummary: base.summary)
            : base.annotations
        return ProviderStructuredOutput(
            verdict: base.verdict,
            confidence: base.confidence,
            summary: clean,
            annotations: annotations
        )
    }

    /// Choose the review to store. Prefer the CLI's final answer; if that
    /// summary is degenerate, fall back to the captured attempt with the
    /// longest recovered summary when it's clearly richer. Returns nil only
    /// when nothing decodes at all.
    static func best(final: Data?, attempts: [Data]) -> ProviderStructuredOutput? {
        let finalDecoded = final.flatMap(decodeLenient)

        if let finalDecoded, !isDegenerate(finalDecoded.summary) {
            return finalDecoded
        }

        let richestAttempt = attempts
            .compactMap(decodeLenient)
            .max(by: { $0.summary.count < $1.summary.count })

        if let richestAttempt,
           !isDegenerate(richestAttempt.summary),
           richestAttempt.summary.count > (finalDecoded?.summary.count ?? 0) {
            return richestAttempt
        }

        return finalDecoded
    }
}
