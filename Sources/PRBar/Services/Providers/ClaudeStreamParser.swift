import Foundation

/// State accumulated as we read lines from `claude --output-format stream-json`.
/// Updated incrementally so callers can enforce budgets mid-stream and
/// SIGTERM the subprocess before the cap is exceeded.
struct ClaudeStreamState: Sendable {
    var sessionID: String?

    var toolCallCount: Int = 0
    var toolNamesUsed: [String] = []
    var permissionDenials: [String] = []

    /// Filled by the final `result` event.
    var costUsd: Double?
    var isError: Bool?
    var apiErrorStatus: String?
    var resultText: String?
    var structuredOutput: Data?
    var terminalReason: String?

    /// True once we've parsed the final `result` event.
    var receivedResult: Bool = false

    /// Auth source the CLI is using, as reported by the `system` init
    /// event. Recent claude versions emit `apiKeySource`; we accept any
    /// of the few keys we've seen in the wild. Examples seen:
    ///   - "ANTHROPIC_API_KEY" / "/login" / "subscription" / "oauth"
    /// `nil` means the CLI didn't report a source (older versions, or
    /// the event wasn't a system one).
    var apiKeySource: String?

    /// True when the CLI run is being charged via the user's Claude
    /// subscription rather than per-token API billing. The CLI still
    /// emits `total_cost_usd` (API-equivalent cost) for budgeting, but
    /// it's informational — actual money charged is $0. Heuristic: any
    /// `apiKeySource` that *isn't* an API-key indicator is treated as
    /// subscription. Defaults to `false` when we can't tell, so we err
    /// on the side of showing the cost as real.
    var isSubscriptionAuth: Bool {
        guard let src = apiKeySource?.lowercased() else { return false }
        // Known API-key indicators — anything else (login/oauth/subscription/...) implies subscription.
        let apiKeyMarkers = ["api_key", "anthropic_api_key", "x-api-key", "apikey"]
        return !apiKeyMarkers.contains(where: { src.contains($0) })
    }
}

enum ClaudeStreamParser {
    /// Parse one JSONL line from the stream. Updates `state` in place.
    /// Tolerant of unknown event types (e.g. `rate_limit_event`,
    /// `system_log`); silently ignores them. Tolerant of malformed JSON
    /// (silently ignores — the stream may have intermediate garbage).
    static func parseEvent(line: String, into state: inout ClaudeStreamState) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let obj = raw as? [String: Any]
        else { return }

        guard let type = obj["type"] as? String else { return }

        switch type {
        case "system":
            if let id = obj["session_id"] as? String { state.sessionID = id }
            // claude CLI 1.x reports the auth source on the init system
            // event under one of these keys (varies across versions).
            if state.apiKeySource == nil {
                if let src = obj["apiKeySource"] as? String {
                    state.apiKeySource = src
                } else if let src = obj["api_key_source"] as? String {
                    state.apiKeySource = src
                } else if let src = obj["authSource"] as? String {
                    state.apiKeySource = src
                }
            }

        case "assistant":
            // assistant.message.content is an array of blocks; tool_use blocks
            // have name="<ToolName>".
            if let message = obj["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content {
                    if (block["type"] as? String) == "tool_use" {
                        state.toolCallCount += 1
                        if let name = block["name"] as? String {
                            state.toolNamesUsed.append(name)
                        }
                    }
                }
            }

        case "result":
            state.receivedResult = true
            state.isError = obj["is_error"] as? Bool
            state.apiErrorStatus = obj["api_error_status"] as? String
            state.costUsd = obj["total_cost_usd"] as? Double
            state.resultText = obj["result"] as? String
            state.terminalReason = obj["terminal_reason"] as? String
            if let denials = obj["permission_denials"] as? [String] {
                state.permissionDenials = denials
            }
            if let so = obj["structured_output"] {
                // Re-serialize to Data — caller will decode against their
                // own type. Ignore re-encode failures (would only happen
                // if NSNumber types confuse JSONSerialization, very rare).
                state.structuredOutput = try? JSONSerialization.data(withJSONObject: so)
            }

        default:
            // rate_limit_event, system_log, user (tool_result echoes), etc.
            break
        }
    }

    /// Convenience: run the parser over the entire combined output (all
    /// JSONL lines concatenated) and return the final state. Useful for
    /// post-hoc parsing (when not enforcing budgets live).
    static func parseFull(_ stream: String) -> ClaudeStreamState {
        var state = ClaudeStreamState()
        for line in stream.split(separator: "\n", omittingEmptySubsequences: true) {
            parseEvent(line: String(line), into: &state)
        }
        return state
    }

    enum BudgetVerdict: Sendable, Hashable {
        case ok
        case toolCallsExceeded(count: Int, max: Int)
        case costExceeded(cost: Double, max: Double)

        var shouldKill: Bool {
            switch self {
            case .ok: return false
            case .toolCallsExceeded, .costExceeded: return true
            }
        }
    }

    /// Check whether the running review has blown its budget. Call after
    /// every line; `claude` is a long-running subprocess so live checks
    /// are how we keep cost predictable.
    static func budgetVerdict(
        state: ClaudeStreamState,
        maxToolCalls: Int,
        maxCostUsd: Double
    ) -> BudgetVerdict {
        if state.toolCallCount > maxToolCalls {
            return .toolCallsExceeded(count: state.toolCallCount, max: maxToolCalls)
        }
        if let cost = state.costUsd, cost > maxCostUsd {
            return .costExceeded(cost: cost, max: maxCostUsd)
        }
        return .ok
    }
}
