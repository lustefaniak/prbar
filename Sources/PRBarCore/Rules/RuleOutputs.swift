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
    enum Kind: Sendable {
        case string
        case bool
        case int
        case oneOf([String])
        case severity
    }

    struct Field: Sendable {
        var name: String
        var kind: Kind
        var required = false
        /// For the JSON schema, which editors show as you type.
        var help: String
        /// Per allowed value, for `oneOf`.
        var values: [String: String] = [:]
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
            var entries: [(line: Int, text: String)] = []
            var seen: Set<String> = []
            for (fieldNode, valueNode) in mapping {
                guard let name = fieldNode.string else { throw problem(fieldNode, "an output field name must be a plain word") }
                guard let field = fields.first(where: { $0.name == name }) else {
                    throw problem(fieldNode, "'\(name)' is not an output field here (fields: \(fields.map(\.name).joined(separator: ", ")))")
                }
                guard let scalar = valueNode.scalar, scalar.style != .literal, scalar.style != .folded else {
                    throw problem(valueNode, "'\(name)' takes a single value, written on its line")
                }
                guard let line = valueNode.mark?.line, line == fieldNode.mark?.line else {
                    throw problem(fieldNode, "write '\(name)' and its value on one line")
                }
                let cel = try literal(scalar.string, for: field) { problem(valueNode, $0) }
                seen.insert(name)
                entries.append((line, "\"\(name)\": \(cel)"))
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
            // and each field line carries one entry, so every line keeps its
            // number. YAML folds the line breaks into spaces.
            guard Set(entries.map(\.line)).count == entries.count else {
                throw problem(value, "write one output field per line")
            }
            let last = entries.map(\.line).max() ?? keyLine
            lines[keyIndex] = prefix + " '{"
            // Comments and blank lines between the fields would land inside
            // the string; blank, they fold away.
            for index in (keyLine + 1)...max(keyLine + 1, last) {
                lines[index - 1] = ""
            }
            for (offset, entry) in entries.sorted(by: { $0.line < $1.line }).enumerated() {
                let indent = String(repeating: " ", count: (mapping.first?.key.mark?.column ?? 2) - 1)
                let comma = offset == entries.count - 1 ? "}'" : ","
                lines[entry.line - 1] = indent + yamlQuoted(entry.text) + comma
            }
        }
        return lines.joined(separator: "\n")
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

    private static func literal(_ raw: String, for field: Field, problem: (String) -> Problem) throws -> String {
        switch field.kind {
        case .string:
            return celString(raw)
        case .bool:
            switch raw {
            case "true": return "true"
            case "false": return "false"
            default: throw problem("'\(field.name)' is true or false, not '\(raw)'")
            }
        case .int:
            guard let n = Int(raw), n >= 0 else { throw problem("'\(field.name)' is a whole number, not '\(raw)'") }
            return String(n)
        case .oneOf(let allowed):
            guard allowed.contains(raw) else {
                throw problem("'\(field.name)' is one of \(allowed.joined(separator: ", ")), not '\(raw)'")
            }
            return celString(raw)
        case .severity:
            let names = AnnotationSeverity.allCases.map(\.rawValue)
            let name = raw.hasPrefix("severity.") ? String(raw.dropFirst("severity.".count)) : raw
            guard names.contains(name) else {
                throw problem("'\(field.name)' is one of \(names.joined(separator: ", ")), not '\(raw)'")
            }
            return "severity.\(name)"
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
