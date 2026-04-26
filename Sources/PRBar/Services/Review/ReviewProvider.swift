import Foundation

/// What we hand to a `ReviewProvider`. Built by `ContextAssembler` from a
/// PRSnapshot + Subdiff + the loaded prompt library.
struct PromptBundle: Sendable {
    /// The system prompt — base + optional per-language override.
    let systemPrompt: String

    /// The user-side prompt: PR meta, file list, existing comments, CI
    /// failures (if any), the diff slice. Markdown.
    let userPrompt: String

    /// Working directory for the subprocess. In `.minimal` tool mode this
    /// is the on-disk subfolder Claude reads from (so `<cwd>/CLAUDE.md`
    /// + `<cwd>/.mcp.json` resolve). In `.none` mode it can point to a
    /// temp dir so there's nothing to read accidentally.
    let workdir: URL

    /// Convenience metadata; not part of the prompt itself.
    let prNodeId: String
    let subpath: String          // empty string = "repo root"
}

struct ProviderOptions: Sendable {
    /// Optional model override; nil = let the CLI pick its default
    /// (typically "sonnet" for `claude`).
    var model: String?

    var toolMode: ToolMode = .minimal

    /// Extra `--add-dir` paths beyond the workdir (e.g. for cross-subfolder
    /// shared schemas). Empty = just the workdir.
    var additionalAddDirs: [URL] = []

    /// Hard cap; provider kills the subprocess if exceeded mid-run.
    var maxToolCalls: Int = 10
    var maxCostUsd: Double = 0.30

    /// Hard ceiling for the whole `claude -p` call. SIGTERM-then-SIGKILL on
    /// timeout. Default is generous because tool-mode reviews can take a
    /// while; pure-prompt mode finishes much faster.
    var timeout: Duration = .seconds(120)

    /// JSON Schema bytes for `--json-schema`. Always required so the
    /// provider doesn't have to load it itself.
    var schema: Data
}

struct ProviderResult: Sendable, Codable {
    let verdict: ReviewVerdict
    let confidence: Double
    let summaryMarkdown: String
    let annotations: [DiffAnnotation]

    /// Total cost as reported by the provider's CLI (e.g. claude's
    /// `total_cost_usd`). Nil when the provider doesn't expose it.
    let costUsd: Double?

    /// Number of tool invocations the AI made during this review. 0 in
    /// pure-prompt mode.
    let toolCallCount: Int

    /// Names of tools used (e.g. ["Read", "Grep", "WebFetch"]). For
    /// diagnostics + the per-row "used Read 2x, Grep 1x" UI.
    let toolNamesUsed: [String]

    /// Raw JSON wrapper as emitted by the CLI, for debugging and audit
    /// (includes the tool-use trace if minimal-tools was used).
    let rawJson: Data

    /// True when the CLI ran against a subscription auth (Claude Max /
    /// Pro), which means `costUsd` is API-equivalent / informational —
    /// the user is not actually billed per-token. The UI grays out the
    /// cost label in this case. Defaults to false so we err on the side
    /// of showing real-money UI when uncertain.
    var isSubscriptionAuth: Bool = false
}

/// Snapshot of an in-flight review. Surfaced to callers via the
/// `onProgress` closure on `ReviewProvider.review` so the UI can render
/// "AI is reading X.swift" / "$0.04 spent so far" while the run executes.
struct ReviewProgress: Sendable, Hashable {
    /// Cumulative tool invocations the AI has made so far.
    var toolCallCount: Int = 0
    /// Names in invocation order (deduped). Last entry is the most recent
    /// tool the AI used.
    var toolNamesUsed: [String] = []
    /// Cumulative cost-so-far (claude reports `total_cost_usd` on the
    /// terminal `result` event; `nil` until then). Nil while running.
    var costUsdSoFar: Double? = nil
    /// Last assistant text snippet (truncated), if any. Useful to show
    /// "AI is thinking about X…" in the UI.
    var lastAssistantText: String? = nil
}

protocol ReviewProvider: Sendable {
    /// Stable identifier ("claude" / "codex" / "gemini").
    var id: String { get }

    /// User-facing name ("Claude").
    var displayName: String { get }

    /// Cheap probe: is the CLI installed and authenticated? Run on app
    /// launch to surface setup issues in the UI.
    func availability() async -> ProviderAvailability

    /// Run one review. Throws on any unrecoverable error (CLI missing,
    /// timeout, schema-validation failure, budget exceeded). The optional
    /// `onProgress` closure is invoked from a background context every
    /// time the provider has new state to share — providers that don't
    /// stream may simply call it once before returning.
    func review(
        bundle: PromptBundle,
        options: ProviderOptions,
        onProgress: (@Sendable (ReviewProgress) -> Void)?
    ) async throws -> ProviderResult
}

extension ReviewProvider {
    /// Convenience: most callers don't care about progress.
    func review(bundle: PromptBundle, options: ProviderOptions) async throws -> ProviderResult {
        try await review(bundle: bundle, options: options, onProgress: nil)
    }
}
