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
}
