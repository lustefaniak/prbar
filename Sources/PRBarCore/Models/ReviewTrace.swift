import Foundation

/// Structured replay of a single subreview's claude-CLI run, derived
/// from the JSONL stream we already capture in `ProviderResult.rawJson`.
/// Purpose: let the user inspect *how* the AI arrived at a verdict —
/// what it read, what it searched for, what it said between tool calls.
///
/// Two audiences:
///   1. The user, building confidence that the AI is doing what it
///      should (and isn't doing what it shouldn't).
///   2. Us, optimizing prompts — seeing where the AI wastes tool calls
///      or misses context tells us what to add to the system prompt.
///
/// The trace is purely derived; no extra storage cost beyond the rawJson
/// we already keep. Re-parse on demand when the user expands the view.
struct ReviewTrace: Sendable, Hashable {
    let events: [ReviewTraceEvent]

    /// Empty trace = couldn't parse anything useful (corrupt stream or
    /// older claude version without the events we expect).
    var isEmpty: Bool { events.isEmpty }
}

/// One step in the AI's reasoning timeline.
enum ReviewTraceEvent: Sendable, Hashable {
    /// A free-text turn from the assistant — what it's thinking before /
    /// between / after tool calls. Empty-text turns are dropped during
    /// parsing.
    case assistantText(text: String)

    /// AI invoked a tool. `inputSummary` is a short, human-readable
    /// rendering of the tool's parameters (e.g. `Read kernel-billing/log.go`),
    /// suitable for a one-line row. `inputJson` keeps the raw input for
    /// the disclosure detail.
    case toolCall(name: String, inputSummary: String, inputJson: String)

    /// Tool result echoed back. Truncated to the first ~400 characters
    /// to keep memory bounded; the raw output stays in the streamed JSON.
    case toolResult(toolName: String?, preview: String, ok: Bool)

    /// Subscription rate-limit ping (informational).
    case rateLimit(status: String)

    /// Final summary event. `verdict` is a passthrough string (parser
    /// stays decoupled from `ReviewVerdict`).
    case finalResult(costUsd: Double?, durationMs: Int?, verdict: String?)
}
