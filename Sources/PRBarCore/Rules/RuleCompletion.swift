import Foundation

/// What to offer while a rule file is typed, from the text before the
/// cursor: facts and functions inside a condition, output fields and their
/// values inside `output:`, and the policy's own keys elsewhere. Pure, so
/// the editor only shows what this returns.
enum RuleCompletion {
    struct Item: Hashable, Sendable {
        enum Kind: Sendable { case fact, function, list, constant, field, value, key }
        /// Replaces the token being typed.
        var insert: String
        var label: String
        var detail: String
        var kind: Kind
    }

    struct Result: Equatable, Sendable {
        /// UTF-16 offset of the token being completed; it runs to the cursor.
        var tokenStart: Int
        var items: [Item]
    }

    /// - Parameters:
    ///   - cursor: UTF-16 offset.
    ///   - stage: from the file's directory; nil for lists.yaml.
    static func complete(
        _ text: String, cursor: Int, stage: RuleCatalog.Stage?, lists: [String] = []
    ) -> Result {
        let utf16 = Array(text.utf16)
        let end = min(max(0, cursor), utf16.count)
        var lineStart = end
        while lineStart > 0, utf16[lineStart - 1] != 10 { lineStart -= 1 }
        let line = String(decoding: utf16[lineStart..<end], as: UTF16.self)
        guard let stage else { return Result(tokenStart: end, items: []) }

        if let cel = celPart(line) {
            let token = trailingToken(cel)
            let start = end - token.utf16.count
            return Result(tokenStart: start + prefixLength(token), items: celItems(token, stage: stage, lists: lists))
        }
        let before = String(decoding: utf16[0..<lineStart], as: UTF16.self)
        if let fields = outputFields(before: before, line: line, stage: stage) {
            return outputItems(line: line, fields: fields, end: end)
        }
        let word = trailingWord(line)
        let keys = ["name: ", "description: ", "rule:", "match:", "variables:", "- condition: ", "condition: ", "output:", "explanation: "]
        let items = keys.filter { $0.hasPrefix(word) && !word.isEmpty || word.isEmpty }
            .map { Item(insert: $0, label: $0.trimmingCharacters(in: .whitespaces), detail: "policy key", kind: .key) }
        return Result(tokenStart: end - word.utf16.count, items: items)
    }

    // MARK: - CEL

    /// The CEL written so far on a `condition:` or `expression:` line, or
    /// on a line continuing one (`>-` blocks).
    private static func celPart(_ line: String) -> String? {
        for key in ["condition:", "expression:"] {
            if let range = line.range(of: key) {
                return String(line[range.upperBound...])
            }
        }
        // Inside a block scalar the line is indented text with no key.
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, !trimmed.hasPrefix("-"), !trimmed.hasPrefix("#"), !trimmed.contains(": "),
           trimmed.contains(where: { "().&|=<>!\"".contains($0) }) {
            return line
        }
        return nil
    }

    /// The identifier path being typed: `pr.fi`, `lists.`, `rev`.
    private static func trailingToken(_ text: String) -> String {
        var scalars: [Character] = []
        for c in text.reversed() {
            if c.isLetter || c.isNumber || c == "_" || c == "." || c == "[" || c == "]" {
                scalars.append(c)
            } else {
                break
            }
        }
        return String(scalars.reversed())
    }

    /// How much of the token stays: everything up to the last dot.
    private static func prefixLength(_ token: String) -> Int {
        guard let dot = token.lastIndex(of: ".") else { return 0 }
        return token[...dot].utf16.count
    }

    private static func celItems(_ token: String, stage: RuleCatalog.Stage, lists: [String]) -> [Item] {
        let facts = RuleCatalog.facts(stage)
        let parent: String
        let partial: String
        if let dot = token.lastIndex(of: ".") {
            parent = String(token[..<dot])
            partial = String(token[token.index(after: dot)...])
        } else {
            parent = ""
            partial = token
        }
        func matching(_ name: String) -> Bool { partial.isEmpty || name.lowercased().hasPrefix(partial.lowercased()) }
        var items: [Item] = []
        if parent.isEmpty {
            for fact in facts where fact.parent.isEmpty && matching(fact.name) {
                items.append(Item(insert: fact.name, label: fact.name, detail: "\(fact.type): \(fact.help)", kind: .fact))
            }
            for function in RuleCatalog.functions where !function.isMethod && matching(function.name) {
                items.append(Item(insert: function.name + "(", label: function.signature, detail: function.help, kind: .function))
            }
            if matching("severity") {
                items.append(Item(insert: "severity", label: "severity", detail: "severity.info … severity.blocker, compared by rank", kind: .constant))
            }
            return items
        }
        if parent == "lists" {
            return lists.filter(matching).map { Item(insert: $0, label: $0, detail: "from lists.yaml", kind: .list) }
        }
        if parent == "severity" {
            return AnnotationSeverity.allCases.map(\.rawValue).filter(matching)
                .map { Item(insert: $0, label: $0, detail: "severity", kind: .constant) }
        }
        let children = facts.filter { $0.parent == parent && matching($0.name) }
        if !children.isEmpty {
            items = children.map { Item(insert: $0.name, label: $0.name, detail: "\($0.type): \($0.help)", kind: .fact) }
        }
        // A fact that is a value: its methods.
        if let fact = facts.first(where: { $0.path == parent }) {
            let methods: [String]
            switch fact.kind {
            case .string: methods = ["contains", "startsWith", "endsWith", "matches", "lowerAscii", "size"]
            case .list: methods = ["exists", "all", "filter", "map", "size"]
            default: methods = []
            }
            for name in methods where matching(name) {
                guard let function = RuleCatalog.functions.first(where: { $0.name == name }) else { continue }
                items.append(Item(insert: name + "(", label: function.signature, detail: function.help, kind: .function))
            }
        }
        return items
    }

    // MARK: - outputs

    /// The fields that can be written at the cursor when it is inside an
    /// `output:` mapping (or a block under one), else nil.
    private static func outputFields(before: String, line: String, stage: RuleCatalog.Stage) -> [RuleOutputs.Field]? {
        let indent = line.prefix { $0 == " " }.count
        var nested: [String] = []
        var depth = indent
        for previous in before.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let text = String(previous)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let level = text.prefix { $0 == " " }.count
            guard level < depth else { continue }
            depth = level
            let key = trimmed.hasPrefix("- ") ? String(trimmed.dropFirst(2)) : trimmed
            guard key.hasSuffix(":") else { return nil }
            let name = String(key.dropLast())
            if name == "output" {
                var fields = fields(stage)
                for block in nested.reversed() {
                    guard let field = fields.first(where: { $0.name == block }), case .object(let inner) = field.kind else { return nil }
                    fields = inner
                }
                return fields
            }
            nested.append(name)
        }
        return nil
    }

    private static func fields(_ stage: RuleCatalog.Stage) -> [RuleOutputs.Field] {
        switch stage {
        case .configure: return RuleOutputs.configure
        case .select: return RuleOutputs.select
        case .decide: return RuleOutputs.decide
        }
    }

    private static func outputItems(line: String, fields: [RuleOutputs.Field], end: Int) -> Result {
        if let colon = line.firstIndex(of: ":") {
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let typed = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard let field = fields.first(where: { $0.name == key }) else { return Result(tokenStart: end, items: []) }
            let values: [String]
            switch field.kind {
            case .oneOf(let allowed): values = allowed
            case .bool: values = ["true", "false"]
            case .severity: values = AnnotationSeverity.allCases.map(\.rawValue)
            default: values = []
            }
            let items = values.filter { typed.isEmpty || $0.hasPrefix(typed) }
                .map { Item(insert: $0, label: $0, detail: field.values[$0] ?? field.help, kind: .value) }
            return Result(tokenStart: end - typed.utf16.count, items: items)
        }
        let word = line.trimmingCharacters(in: .whitespaces)
        let items = fields.filter { word.isEmpty || $0.name.hasPrefix(word) }.map { field -> Item in
            let suffix: String
            if case .object = field.kind { suffix = ":" } else { suffix = ": " }
            return Item(insert: field.name + suffix, label: field.name, detail: field.help, kind: .field)
        }
        return Result(tokenStart: end - word.utf16.count, items: items)
    }

    private static func trailingWord(_ line: String) -> String {
        String(line.reversed().prefix { !$0.isWhitespace }.reversed())
    }
}
