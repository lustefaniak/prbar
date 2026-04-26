import Foundation

/// Pure function: walk a JSONL stream from `claude --output-format
/// stream-json --verbose` and return a structured replay (`ReviewTrace`).
///
/// Tolerant of unknown event types and malformed lines (matches the
/// existing `ClaudeStreamParser`). Tool-result preview text is truncated
/// to bound memory; the raw stream is still available on disk.
enum ReviewTraceParser {
    /// Cap on the preview substring kept per tool result. Tool outputs
    /// can be huge (file reads); we only show a teaser.
    static let toolResultPreviewLimit = 400

    static func parse(_ stream: String) -> ReviewTrace {
        var events: [ReviewTraceEvent] = []
        var toolNamesById: [String: String] = [:]   // tool_use_id → name

        for raw in stream.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let any = try? JSONSerialization.jsonObject(with: data),
                  let obj = any as? [String: Any],
                  let type = obj["type"] as? String
            else { continue }

            switch type {
            case "assistant":
                appendAssistantBlocks(obj: obj, events: &events, toolNamesById: &toolNamesById)
            case "user":
                appendUserBlocks(obj: obj, events: &events, toolNamesById: toolNamesById)
            case "rate_limit_event":
                if let info = obj["rate_limit_info"] as? [String: Any],
                   let status = info["status"] as? String {
                    events.append(.rateLimit(status: status))
                } else {
                    events.append(.rateLimit(status: "limited"))
                }
            case "result":
                events.append(.finalResult(
                    costUsd: obj["total_cost_usd"] as? Double,
                    durationMs: obj["duration_ms"] as? Int,
                    verdict: extractVerdict(obj["structured_output"])
                ))
            default:
                break
            }
        }

        return ReviewTrace(events: events)
    }

    // MARK: - private

    private static func appendAssistantBlocks(
        obj: [String: Any],
        events: inout [ReviewTraceEvent],
        toolNamesById: inout [String: String]
    ) {
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return }
        for block in content {
            guard let kind = block["type"] as? String else { continue }
            switch kind {
            case "text":
                let text = (block["text"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    events.append(.assistantText(text: text))
                }
            case "tool_use":
                let name = (block["name"] as? String) ?? "?"
                let id = (block["id"] as? String) ?? ""
                if !id.isEmpty { toolNamesById[id] = name }
                let input = block["input"] as? [String: Any] ?? [:]
                let summary = summarizeToolInput(name: name, input: input)
                let json = (try? JSONSerialization.data(
                    withJSONObject: input, options: [.prettyPrinted, .sortedKeys]
                )).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                events.append(.toolCall(name: name, inputSummary: summary, inputJson: json))
            default:
                break
            }
        }
    }

    private static func appendUserBlocks(
        obj: [String: Any],
        events: inout [ReviewTraceEvent],
        toolNamesById: [String: String]
    ) {
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return }
        for block in content {
            guard (block["type"] as? String) == "tool_result" else { continue }
            let id = (block["tool_use_id"] as? String) ?? ""
            let toolName = id.isEmpty ? nil : toolNamesById[id]
            let isError = (block["is_error"] as? Bool) ?? false
            let preview = extractResultPreview(block["content"])
            events.append(.toolResult(
                toolName: toolName,
                preview: preview,
                ok: !isError
            ))
        }
    }

    /// Best-effort one-liner for a tool call. Falls back to the tool name
    /// alone when no useful field is present.
    private static func summarizeToolInput(name: String, input: [String: Any]) -> String {
        // The interesting field varies by tool; pick the most distinctive
        // one we know about and fall through to a generic key=value list.
        if let path = input["file_path"] as? String {
            // Read / Edit / Write / Glob / Grep all use file_path
            if let pattern = input["pattern"] as? String { return "\(name) \(path)  '\(pattern)'" }
            if let offset = input["offset"], let limit = input["limit"] {
                return "\(name) \(path) [\(offset):+\(limit)]"
            }
            return "\(name) \(path)"
        }
        if let pattern = input["pattern"] as? String {
            let path = input["path"] as? String
            return "\(name) '\(pattern)'\(path.map { " in \($0)" } ?? "")"
        }
        if let url = input["url"] as? String {
            return "\(name) \(url)"
        }
        if let query = input["query"] as? String {
            return "\(name) '\(query)'"
        }
        if let cmd = input["command"] as? String {
            return "\(name) \(cmd)"
        }
        if input.isEmpty { return name }
        // Fallback: name with first non-trivial key=value
        let pairs = input.prefix(2).map { "\($0.key)=\(briefValue($0.value))" }
        return "\(name) \(pairs.joined(separator: " "))"
    }

    private static func briefValue(_ v: Any) -> String {
        if let s = v as? String { return s.count > 60 ? String(s.prefix(60)) + "…" : s }
        if let n = v as? NSNumber { return n.stringValue }
        return String(describing: v)
    }

    private static func extractResultPreview(_ content: Any?) -> String {
        // Tool results come as either a plain string or an array of
        // {type: text, text: "..."} blocks. Unwrap and truncate.
        let text: String
        if let s = content as? String {
            text = s
        } else if let arr = content as? [[String: Any]] {
            let chunks = arr.compactMap { $0["text"] as? String }
            text = chunks.joined(separator: "\n")
        } else if let any = content {
            text = String(describing: any)
        } else {
            text = ""
        }
        if text.count <= toolResultPreviewLimit { return text }
        return String(text.prefix(toolResultPreviewLimit)) + "…"
    }

    private static func extractVerdict(_ structured: Any?) -> String? {
        guard let dict = structured as? [String: Any] else { return nil }
        return dict["verdict"] as? String
    }
}
