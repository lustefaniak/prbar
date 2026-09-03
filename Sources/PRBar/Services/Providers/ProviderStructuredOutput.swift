import Foundation

/// JSON shape every `ReviewProvider` returns. Matches
/// `Resources/schemas/review.json`. Shared between `ClaudeProvider`
/// (which gets it via `--json-schema` + a `result.structured_output`
/// event) and `CodexProvider` (which reads JSON straight out of stdout
/// — codex doesn't have an equivalent `--json-schema` flag yet).
struct ProviderStructuredOutput: Decodable, Sendable, Hashable {
    let verdict: ReviewVerdict
    let confidence: Double
    let summary: String
    let annotations: [DiffAnnotation]

    init(
        verdict: ReviewVerdict,
        confidence: Double,
        summary: String,
        annotations: [DiffAnnotation]
    ) {
        self.verdict = verdict
        self.confidence = confidence
        self.summary = summary
        self.annotations = annotations
    }

    /// `confidence` and `annotations` are no longer schema-`required`
    /// (see `Resources/schemas/review.json`): claude's `--json-schema`
    /// StructuredOutput tool corrupts the emitted arguments when the
    /// `summary` is long — the closing tag and the `annotations`
    /// parameter leak *into* the summary string, leaving no top-level
    /// `annotations` key. Marking it required turned that into a
    /// "must have required property 'annotations'" rejection loop that
    /// the model escaped by degrading to a placeholder summary (the
    /// infamous "test" reviews). Decoding both fields with a default
    /// keeps the substantive verdict+summary instead of throwing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verdict = try c.decode(ReviewVerdict.self, forKey: .verdict)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0.5
        summary = try c.decode(String.self, forKey: .summary)
        annotations = try c.decodeIfPresent([DiffAnnotation].self, forKey: .annotations) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case verdict, confidence, summary, annotations
    }
}
