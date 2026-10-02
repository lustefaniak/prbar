import Foundation
import Yams

/// Lets a policy write its `output` as plain YAML:
///
/// ```yaml
/// output:
///   rule: share-warnings
///   action: share
///   min_severity: warning
/// ```
///
/// cel-go's policy format wants a CEL expression there
/// (`'{"rule": "share-warnings", "action": "share", "min_severity": severity.warning}'`),
/// which is the line people get wrong most. Each `output` mapping is checked
/// against the stage's fields (names, types, allowed values) with its own
/// file position, then rewritten into that CEL map literal before the policy
/// is parsed, keeping every line where it was so the positions of anything
/// else in the file stay right. A quoted CEL `output` still works, for an
/// output that has to be computed.
enum RuleOutputs {
    indirect enum Kind: Sendable {
        case string
        case bool
        case int
        /// A decimal number, such as a confidence.
        case number
        case oneOf([String])
        case severity
        /// A list of strings: patterns, mostly.
        case strings
        /// Names to strings: environment variables.
        case stringMap
        /// A block of its own fields.
        case object([Field])
    }

    struct Field: Sendable {
        var name: String
        var kind: Kind
        var required = false
        /// For the JSON schema, which editors show as you type.
        var help: String
        /// Per allowed value, for `oneOf`.
        var values: [String: String] = [:]
        /// For `object`: the CEL type, which an empty block is written as,
        /// since `{}` alone has no type to check against.
        var celType: String? = nil
    }

    static let ruleID = Field(
        name: "rule", kind: .string, required: true,
        help: "The rule's id: shown in PRBar with the decision, in `rules history` and in `rules explain`. Make it say what the rule is for.")

    static let select: [Field] = [
        ruleID,
        Field(
            name: "action", kind: .oneOf(RuleSelection.Action.allCases.map(\.rawValue)), required: true,
            help: "Whether PRBar reviews the pull request.",
            values: [
                "review": "Review it, even where the prbar.yaml settings would skip it.",
                "skip": "Don't review it; PRBar shows the reason.",
            ]),
        Field(name: "reason", kind: .string, help: "Shown in PRBar with a skip."),
    ]

    static let decide: [Field] = [
        ruleID,
        Field(
            name: "action", kind: .oneOf(RuleDecision.Action.allCases.map(\.rawValue)), required: true,
            help: "What PRBar posts on its own once the review is in.",
            values: [
                "approve": "A GitHub approval, with an empty body unless `attribution`.",
                "request_changes": "A \"request changes\" review with the summary as its body.",
                "comment": "A comment review with the summary, no verdict.",
                "share": "The findings as inline comments, no verdict and no body, and the review request restored so the next push is reviewed again. Posts nothing when no finding reaches `min_severity`.",
                "flag": "Shown in PRBar as a request for changes; nothing is posted.",
                "none": "Nothing is posted.",
            ]),
        Field(name: "inline", kind: .bool, help: "Post the findings as inline comments. Default: off for approve, on otherwise."),
        Field(name: "min_severity", kind: .severity, help: "Only findings at or above this severity go inline. Default: info."),
        Field(name: "max_comments", kind: .int, help: "At most this many inline comments, worst first. Default: 20 for share, no cap otherwise."),
        Field(name: "attribution", kind: .bool, help: "With approve: a one-line body naming PRBar and the review's confidence."),
    ]

    static let configure: [Field] = [
        Field(
            name: "rule", kind: .string, required: true,
            help: "The rule's id, shown in `rules explain` with the settings it set."),
        Field(name: "split_mode", kind: .oneOf(SplitMode.allCases.map(\.rawValue)),
              help: "One review for the whole PR, or one per subfolder that matches root_patterns.",
              values: ["single": "One review of the whole diff.", "perSubfolder": "One review per subfolder that matches root_patterns."]),
        Field(name: "root_patterns", kind: .strings, help: "Subfolder patterns for perSubfolder, like `kernel-*/`."),
        Field(name: "unmatched_strategy", kind: .oneOf(UnmatchedStrategy.allCases.map(\.rawValue)),
              help: "What happens to changes outside every root pattern."),
        Field(name: "min_files_per_subreview", kind: .int, help: "Fewer changed files than this in a subfolder fold it into the root review."),
        Field(name: "max_parallel_subreviews", kind: .int, help: "Subreviews of one PR run at most this many at a time."),
        Field(name: "collapse_above_subreview_count", kind: .int, help: "More subreviews than this become one review of the whole PR; 0 turns that off."),
        Field(name: "tool_mode", kind: .oneOf(ToolMode.allCases.map(\.rawValue)), help: "What the reviewing agent may use: a sandboxed checkout, read-only tools, or none."),
        Field(name: "custom_system_prompt", kind: .string, help: "Added to the review prompt; an empty string for none."),
        Field(name: "replace_base_system_prompt", kind: .bool, help: "Use custom_system_prompt instead of PRBar's prompt, not beside it."),
        Field(name: "max_tool_calls_per_subreview", kind: .int, help: "A soft cap on the agent's tool calls in one review."),
        Field(name: "max_cost_usd_per_subreview", kind: .number, help: "A review that would cost more is stopped."),
        Field(name: "review_timeout_seconds", kind: .int, help: "A review running longer is stopped."),
        Field(name: "risk_brief_enabled", kind: .bool, help: "Give the review a reading order of the riskiest files."),
        Field(name: "churn_window_days", kind: .int, help: "How far back the risk brief counts a file's recent changes."),
        Field(name: "churn_history_depth", kind: .int, help: "How many commits of history the risk brief reads."),
        Field(name: "auto_approve", kind: .object(autoApprove),
              help: "When PRBar approves on its own. Replaces the default block as a whole: a field left out takes its shipped value, not the default block's.",
              celType: RuleConfiguration.AutoApprove.celTypeName),
        Field(name: "auto_deny", kind: .object(autoDeny),
              help: "When PRBar pushes back on its own. Replaces the default block as a whole.",
              celType: RuleConfiguration.AutoDeny.celTypeName),
        Field(name: "share_findings", kind: .oneOf(ShareFindingsPolicy.allCases.map(\.rawValue)),
              help: "When neither gate fires, post the findings at or above this level as a comment review with no verdict."),
        Field(name: "share_min_confidence", kind: .number, help: "Findings are shared only from a review at least this confident."),
        Field(name: "share_max_comments", kind: .int, help: "At most this many inline comments in one share, worst first."),
        Field(name: "resolve_threads", kind: .object(resolveThreads),
              help: "Resolve PRBar's own threads whose finding is gone and the author replied to.",
              celType: RuleConfiguration.ResolveThreads.celTypeName),
        Field(name: "review_drafts", kind: .bool, help: "Review draft PRs too."),
        Field(name: "exclude_title_patterns", kind: .strings,
              help: "PRs whose title matches are not reviewed. Added to the default patterns; `!pattern` drops one."),
        Field(name: "agent_environment", kind: .stringMap,
              help: "Extra environment variables for the reviewing agent, added to the default ones; a `!NAME` key drops one."),
        Field(name: "skip_ai_if_reviewed_by_others", kind: .bool, help: "Don't review a PR someone else already approved or requested changes on."),
        Field(name: "ai_review_enabled", kind: .bool, help: "Whether PRBar reviews this repository's PRs at all."),
        Field(name: "provider", kind: .oneOf(ProviderID.allCases.map(\.rawValue)), help: "The agent that reviews: claude or codex."),
        Field(name: "claude_model", kind: .string, help: "claude's --model, such as sonnet or opus."),
        Field(name: "claude_effort", kind: .string, help: "claude's --effort: low, medium, high, xhigh or max."),
        Field(name: "codex_model", kind: .string, help: "codex's --model."),
        Field(name: "codex_effort", kind: .string, help: "codex's reasoning effort: none, minimal, low, medium, high or xhigh."),
        Field(name: "notify_policy", kind: .oneOf(NotifyPolicy.allCases.map(\.rawValue)),
              help: "When PRBar tells you a PR is ready for you: as each is ready, or once the inbox settles."),
        Field(name: "skip_merge_confirmation", kind: .bool, help: "Merge from PRBar without asking first."),
        Field(name: "force_full_review", kind: .bool, help: "Review the whole PR again on every push, rather than what changed since the last review."),
    ]

    static let autoApprove: [Field] = [
        Field(name: "enabled", kind: .bool, help: "Approve on its own when every gate below passes."),
        Field(name: "min_confidence", kind: .number, help: "The review's confidence must be at least this. Default 0.85."),
        Field(name: "claude_min_confidence", kind: .number, help: "The floor for claude's reviews, when it differs."),
        Field(name: "codex_min_confidence", kind: .number, help: "The floor for codex's reviews, when it differs."),
        Field(name: "allow_approve_with_notes", kind: .bool, help: "Approve a review whose verdict is 'comment' too."),
        Field(name: "max_annotation_severity", kind: .severity, help: "No finding may be worse than this. Default suggestion."),
        Field(name: "max_annotations", kind: .int, help: "At most this many findings; 0 for no cap."),
        Field(name: "max_additions", kind: .int, help: "At most this many added lines; 0 for no cap. Default 200."),
        Field(name: "max_deletions", kind: .int, help: "At most this many deleted lines; 0 for no cap."),
        Field(name: "max_changed_files", kind: .int, help: "At most this many changed files; 0 for no cap."),
        Field(name: "post_attribution_comment", kind: .bool, help: "Approve with a one-line body naming PRBar."),
        Field(name: "post_inline_annotations", kind: .bool, help: "Post the findings inline with the approval."),
    ]

    static let autoDeny: [Field] = [
        Field(name: "action", kind: .oneOf(AutoDenyAction.allCases.map(\.rawValue)), help: "What a pushback posts: nothing, a flag in PRBar, a comment, or a request for changes."),
        Field(name: "min_confidence", kind: .number, help: "The review's confidence must be at least this. Default 0.85."),
        Field(name: "claude_min_confidence", kind: .number, help: "The floor for claude's reviews, when it differs."),
        Field(name: "codex_min_confidence", kind: .number, help: "The floor for codex's reviews, when it differs."),
        Field(name: "required_severity", kind: .severity, help: "Findings counted are at least this bad. Default warning."),
        Field(name: "min_matching_annotations", kind: .int, help: "At least this many such findings. Default 1."),
        Field(name: "max_additions", kind: .int, help: "Only PRs with at most this many added lines; 0 for no cap."),
        Field(name: "post_inline_annotations", kind: .bool, help: "Post the findings inline with it. Default on."),
    ]

    static let resolveThreads: [Field] = [
        Field(name: "enabled", kind: .bool, help: "Resolve threads PRBar opened once their finding is gone."),
        Field(name: "min_confidence", kind: .number, help: "Only after a review at least this confident. Default 0.85."),
    ]

    struct Problem: Error, CustomStringConvertible {
        var path: String
        var line: Int
        var column: Int
        var message: String
        var sourceLine: String

        var description: String {
            "ERROR: \(path):\(line):\(column): \(message)\n | \(sourceLine)\n | \(String(repeating: ".", count: max(0, column - 1)))^"
        }
    }

    /// The policy text with every YAML `output` mapping replaced by its CEL
    /// map literal. Text that doesn't parse as YAML comes back unchanged, for
    /// the policy parser to report.
    static func expand(_ text: String, path: String, fields: [Field]) throws -> String {
        guard let root = try? Yams.compose(yaml: text) else { return text }
        var outputs: [(key: Node, value: Node)] = []
        collect(root, into: &outputs)
        guard !outputs.isEmpty else { return text }

        var lines = text.components(separatedBy: "\n")
        func problem(_ node: Node?, _ message: String) -> Problem {
            let line = node?.mark?.line ?? 1
            let column = node?.mark?.column ?? 1
            return Problem(
                path: path, line: line, column: column, message: message,
                sourceLine: lines.indices.contains(line - 1) ? lines[line - 1] : "")
        }

        // Bottom up, so a rewrite never moves a later one.
        for (key, value) in outputs.reversed() {
            guard let mapping = value.mapping, let keyLine = key.mark?.line else { continue }
            let fieldIndent = mapping.first?.key.mark?.column ?? 2
            var entries: [(line: Int, end: Int, text: String)] = []
            var seen: Set<String> = []
            let pairs = Array(mapping)
            for (index, (fieldNode, valueNode)) in pairs.enumerated() {
                guard let name = fieldNode.string else { throw problem(fieldNode, "an output field name must be a plain word") }
                guard let field = fields.first(where: { $0.name == name }) else {
                    throw problem(fieldNode, "'\(name)' is not an output field here (fields: \(fields.map(\.name).joined(separator: ", ")))")
                }
                let cel = try literal(valueNode, for: field, name: name) { problem($0, $1) }
                seen.insert(name)
                let line = fieldNode.mark?.line ?? keyLine
                // A value can run over several lines (a list, a block); its
                // CEL goes on the field's line and the rest is blanked.
                let end: Int
                if index + 1 < pairs.count, let next = pairs[index + 1].key.mark?.line {
                    end = next - 1
                } else {
                    end = blockEnd(lines, after: line, indent: fieldIndent)
                }
                entries.append((line, max(line, end), "\"\(name)\": \(cel)"))
            }
            for field in fields where field.required && !seen.contains(field.name) {
                throw problem(key, "the output needs '\(field.name)'")
            }
            let map = "{" + entries.map(\.text).joined(separator: ", ") + "}"

            let keyIndex = keyLine - 1
            let prefix = try keyPrefix(lines[keyIndex], keyColumn: key.mark?.column ?? 1) {
                problem(key, $0)
            }
            if mapping.style == .flow || entries.allSatisfy({ $0.line == keyLine }) {
                guard entries.allSatisfy({ $0.line == keyLine }) else {
                    throw problem(value, "write a {…} output on one line, or as one field per line")
                }
                lines[keyIndex] = prefix + " '" + yamlQuoted(map) + "'"
                continue
            }
            // One field per line: the key line opens a single-quoted string
            // and each field's first line carries its entry, so every line
            // keeps its number. YAML folds the line breaks into spaces.
            guard Set(entries.map(\.line)).count == entries.count else {
                throw problem(value, "write one output field per line")
            }
            lines[keyIndex] = prefix + " '{"
            // Comments, blank lines and the rest of a multi-line value would
            // land inside the string; blank, they fold away.
            let last = entries.map(\.end).max() ?? keyLine
            for index in (keyLine + 1)...max(keyLine + 1, last) where index - 1 < lines.count {
                lines[index - 1] = ""
            }
            for (offset, entry) in entries.sorted(by: { $0.line < $1.line }).enumerated() {
                let indent = String(repeating: " ", count: fieldIndent - 1)
                let comma = offset == entries.count - 1 ? "}'" : ","
                lines[entry.line - 1] = indent + yamlQuoted(entry.text) + comma
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The last line of a block that starts on `line` (1-based): every
    /// later line indented deeper than `indent`, or blank or a comment.
    private static func blockEnd(_ lines: [String], after line: Int, indent: Int) -> Int {
        var end = line
        var index = line
        while index < lines.count {
            let text = lines[index]
            let trimmed = text.drop { $0 == " " }
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                index += 1
                continue
            }
            if text.count - trimmed.count + 1 <= indent { break }
            index += 1
            end = index
        }
        return end
    }

    private static func collect(_ node: Node, into found: inout [(key: Node, value: Node)]) {
        switch node {
        case .mapping(let mapping):
            for (key, value) in mapping {
                if key.string == "output", value.mapping != nil {
                    found.append((key, value))
                } else {
                    collect(value, into: &found)
                }
            }
        case .sequence(let sequence):
            for item in sequence { collect(item, into: &found) }
        case .scalar, .alias:
            break
        }
    }

    private static func literal(
        _ node: Node, for field: Field, name: String, problem: (Node, String) -> Problem
    ) throws -> String {
        switch field.kind {
        case .strings:
            if let scalar = node.scalar, scalar.string.isEmpty || scalar.string == "[]" { return "[]" }
            guard let sequence = node.sequence else { throw problem(node, "'\(name)' is a list, like [a, b]") }
            let items = try sequence.map { item -> String in
                guard let scalar = item.scalar else { throw problem(item, "'\(name)' lists plain values") }
                return celString(scalar.string)
            }
            return "[" + items.joined(separator: ", ") + "]"
        case .stringMap:
            guard let mapping = node.mapping else { throw problem(node, "'\(name)' maps names to values, like {NAME: value}") }
            let items = try mapping.map { key, value -> String in
                guard let k = key.string, let v = value.scalar else { throw problem(key, "'\(name)' maps names to plain values") }
                return celString(k) + ": " + celString(v.string)
            }
            return "{" + items.joined(separator: ", ") + "}"
        case .object(let subfields):
            guard let mapping = node.mapping else {
                throw problem(node, "'\(name)' is a block of fields (\(subfields.map(\.name).joined(separator: ", ")))")
            }
            if mapping.count == 0, let type = field.celType { return type + "{}" }
            var items: [String] = []
            for (key, value) in mapping {
                guard let sub = key.string, let subfield = subfields.first(where: { $0.name == sub }) else {
                    throw problem(key, "'\(key.string ?? "")' is not a field of '\(name)' (fields: \(subfields.map(\.name).joined(separator: ", ")))")
                }
                items.append("\"\(sub)\": " + (try literal(value, for: subfield, name: "\(name).\(sub)", problem: problem)))
            }
            return "{" + items.joined(separator: ", ") + "}"
        case .string, .bool, .int, .number, .oneOf, .severity:
            break
        }
        guard let scalar = node.scalar else { throw problem(node, "'\(name)' takes a single value") }
        let raw = scalar.string
        switch field.kind {
        case .string:
            return celString(raw)
        case .bool:
            switch raw {
            case "true": return "true"
            case "false": return "false"
            default: throw problem(node, "'\(name)' is true or false, not '\(raw)'")
            }
        case .int:
            guard let n = Int(raw), n >= 0 else { throw problem(node, "'\(name)' is a whole number, not '\(raw)'") }
            return String(n)
        case .number:
            guard let n = Double(raw), n >= 0, n.isFinite else { throw problem(node, "'\(name)' is a number, not '\(raw)'") }
            return String(n)
        case .oneOf(let allowed):
            guard allowed.contains(raw) else {
                throw problem(node, "'\(name)' is one of \(allowed.joined(separator: ", ")), not '\(raw)'")
            }
            return celString(raw)
        case .severity:
            let names = AnnotationSeverity.allCases.map(\.rawValue)
            let short = raw.hasPrefix("severity.") ? String(raw.dropFirst("severity.".count)) : raw
            guard names.contains(short) else {
                throw problem(node, "'\(name)' is one of \(names.joined(separator: ", ")), not '\(raw)'")
            }
            return "severity.\(short)"
        case .strings, .stringMap, .object:
            fatalError("handled above")
        }
    }

    private static func celString(_ raw: String) -> String {
        var out = "\""
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// Single quotes double inside a single-quoted YAML scalar.
    private static func yamlQuoted(_ text: String) -> String {
        text.replacingOccurrences(of: "'", with: "''")
    }

    /// The key line up to and including `output:`.
    private static func keyPrefix(_ line: String, keyColumn: Int, problem: (String) -> Problem) throws -> String {
        let scalars = Array(line.unicodeScalars)
        var index = max(0, keyColumn - 1)
        while index < scalars.count, scalars[index] != ":" { index += 1 }
        guard index < scalars.count else { throw problem("expected 'output:'") }
        var prefix = String.UnicodeScalarView()
        prefix.append(contentsOf: scalars[...index])
        return String(prefix)
    }
}
