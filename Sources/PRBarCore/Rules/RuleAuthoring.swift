import Foundation

/// Rules to start from: each one a whole file that compiles, adjusting what
/// Review defaults decide in one common way.
enum RuleExamples {
    struct Example: Identifiable, Sendable, Hashable {
        var id: String
        var stage: RuleCatalog.Stage
        var title: String
        var detail: String
        /// The file name in the stage's directory.
        var file: String
        var text: String
        /// Lists the example reads, added to lists.yaml when missing.
        var lists: [String: [String]] = [:]

        var path: String { "\(stage.rawValue)/\(file)" }
    }

    /// - Parameter repository: a repository to show in the examples, one
    ///   the user has; a placeholder otherwise.
    static func all(repository: String? = nil, viewer: String? = nil) -> [Example] {
        let repo = repository ?? "my-org/my-repo"
        let owner = repo.split(separator: "/").first.map(String.init) ?? "my-org"
        let me = viewer ?? "me"
        return [
            Example(
                id: "configure-repo", stage: .configure, title: "Settings for one repository",
                detail: "A budget, a model and drafts for \(repo); everything else from Review defaults.",
                file: "20-\(slug(repo)).yaml", text: """
                    name: \(slug(repo))
                    rule:
                      match:
                        - condition: repo.full_name == \(RulesConvert.quoted(repo))
                          output:
                            rule: \(slug(repo))
                            max_cost_usd_per_subreview: 2
                            claude_model: sonnet
                            review_drafts: false

                    """),
            Example(
                id: "configure-monorepo", stage: .configure, title: "Review a monorepo per folder",
                detail: "One review per service folder, folded into one when a PR touches too many.",
                file: "20-monorepo.yaml", text: """
                    name: monorepo
                    rule:
                      match:
                        - condition: repo.full_name == \(RulesConvert.quoted(repo))
                          output:
                            rule: monorepo-split
                            split_mode: perSubfolder
                            root_patterns: [services/*/, lib/*/]
                            min_files_per_subreview: 3
                            collapse_above_subreview_count: 4

                    """),
            Example(
                id: "configure-approve-owner", stage: .configure, title: "Auto-approve small changes in an organisation",
                detail: "Turns auto-approve on for \(owner)'s repositories, for confident reviews of small changes.",
                file: "30-approve-small.yaml", text: """
                    name: approve-small
                    rule:
                      match:
                        - condition: repo.owner == \(RulesConvert.quoted(owner))
                          output:
                            rule: approve-small
                            auto_approve:
                              enabled: true
                              min_confidence: 0.9
                              max_annotation_severity: suggestion
                              max_additions: 150

                    """),
            Example(
                id: "select-drafts", stage: .select, title: "Skip drafts",
                detail: "Drafts wait until they are ready for review.",
                file: "10-drafts.yaml", text: """
                    name: drafts
                    rule:
                      match:
                        - condition: pr.draft
                          output:
                            rule: skip-drafts
                            action: skip
                            reason: drafts wait until they are ready

                    """),
            Example(
                id: "select-bots", stage: .select, title: "Skip small changes from bots",
                detail: "Dependency bumps and the like, when they are small.",
                file: "20-bots.yaml", text: """
                    name: bots
                    rule:
                      match:
                        - condition: pr.author_is_bot && pr.additions + pr.deletions < 50
                          output:
                            rule: skip-small-bot-changes
                            action: skip
                            reason: a small change from a bot

                    """),
            Example(
                id: "select-docs", stage: .select, title: "Skip documentation-only changes",
                detail: "Reads the changed files, fetched only when this rule needs them.",
                file: "30-docs.yaml", text: """
                    name: docs
                    rule:
                      match:
                        - condition: only(pr.files, "docs/**") || only(pr.files, "**.md")
                          output:
                            rule: skip-docs
                            action: skip
                            reason: documentation only

                    """),
            Example(
                id: "select-others", stage: .select, title: "Skip what someone else already reviewed",
                detail: "Another person approved or asked for changes.",
                file: "40-reviewed.yaml", text: """
                    name: reviewed
                    rule:
                      match:
                        - condition: pr.reviewed_by_others
                          output:
                            rule: skip-reviewed-by-others
                            action: skip
                            reason: someone else already reviewed it

                    """),
            Example(
                id: "decide-trusted", stage: .decide, title: "Auto-approve only some authors",
                detail: "Where Review defaults would approve, share the findings instead unless the author is on your trusted list.",
                file: "10-trusted.yaml", text: """
                    name: trusted
                    rule:
                      match:
                        - condition: below.action == "approve" && !(pr.author in lists.trusted)
                          output:
                            rule: approve-only-trusted
                            action: share
                            min_severity: suggestion

                    """, lists: ["trusted": [me]]),
            Example(
                id: "decide-large", stage: .decide, title: "Share instead of approving large changes",
                detail: "A large change gets a human verdict; the findings are shared meanwhile.",
                file: "20-large.yaml", text: """
                    name: large
                    rule:
                      match:
                        - condition: below.action == "approve" && pr.additions > 400
                          output:
                            rule: large-gets-a-human
                            action: share

                    """),
            Example(
                id: "decide-codeowner", stage: .decide, title: "Approve a code owner's clean change",
                detail: "The author owns every changed file in CODEOWNERS and the review found nothing above a suggestion. CODEOWNERS is fetched only when this rule needs it.",
                file: "25-codeowner.yaml", text: """
                    name: codeowner
                    rule:
                      match:
                        - condition: >-
                            review.verdict == "approve" && review.confidence >= 0.85
                            && review.max_severity <= severity.suggestion
                            && pr.codeowners.all(f, pr.author in f.owners)
                          output:
                            rule: codeowner-approves
                            action: approve

                    """),
            Example(
                id: "decide-sensitive", stage: .decide, title: "Never post on its own when sensitive files change",
                detail: "Auth, secrets, crypto: flagged in PRBar, nothing posted.",
                file: "05-sensitive.yaml", text: """
                    name: sensitive
                    rule:
                      match:
                        - condition: pr.files.exists(f, f.sensitive)
                          output:
                            rule: sensitive-needs-a-human
                            action: flag

                    """),
            Example(
                id: "decide-blockers", stage: .decide, title: "Request changes on a blocker",
                detail: "A confident review that found a blocker asks for changes, with the findings inline.",
                file: "30-blockers.yaml", text: """
                    name: blockers
                    rule:
                      match:
                        - condition: review.max_severity == severity.blocker && review.confidence >= 0.8
                          output:
                            rule: request-changes-on-blockers
                            action: request_changes
                            min_severity: warning

                    """),
        ]
    }

    static func slug(_ text: String) -> String {
        let id = String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return id.split(separator: "-").joined(separator: "-")
    }
}

/// A rule put together from choices rather than typed: conditions joined by
/// `&&` or `||`, and output fields. `yaml` writes the file it stands for.
struct RuleBuilder: Equatable, Sendable {
    enum Operator: String, CaseIterable, Sendable, Identifiable {
        case isTrue = "is true"
        case isFalse = "is false"
        case equals = "is"
        case notEquals = "is not"
        case greater = "is more than"
        case less = "is less than"
        case inList = "is in the list"
        case notInList = "is not in the list"
        case globs = "matches the pattern"
        case contains = "contains"
        case startsWith = "starts with"
        case anyFile = "has a file matching"
        case everyFile = "only has files matching"
        case longer = "is longer than"
        case shorter = "is shorter than"

        var id: String { rawValue }

        /// Whether it compares with a value the user types.
        var takesValue: Bool { self != .isTrue && self != .isFalse }
    }

    struct Condition: Equatable, Sendable, Identifiable {
        var id = UUID()
        var fact: String
        var op: Operator
        var value: String = ""
    }

    var stage: RuleCatalog.Stage
    var name: String
    var conditions: [Condition] = []
    /// All must hold (`&&`), or any (`||`).
    var all = true
    /// By output field name; a nested block's fields as `auto_approve.enabled`.
    /// A list is written comma separated.
    var outputs: [String: String] = [:]

    static func operators(for kind: RuleCatalog.Kind, path: String) -> [Operator] {
        switch kind {
        case .bool: return [.isTrue, .isFalse]
        case .int, .double: return [.greater, .less, .equals, .notEquals]
        case .string: return [.equals, .notEquals, .inList, .notInList, .globs, .contains, .startsWith]
        case .duration: return [.longer, .shorter]
        case .list(let element) where element.hasSuffix(".File"): return [.anyFile, .everyFile]
        case .list: return [.contains]
        default: return []
        }
    }

    /// The facts a condition can be built on: values, not objects.
    static func facts(_ stage: RuleCatalog.Stage) -> [RuleCatalog.Fact] {
        RuleCatalog.facts(stage).filter { fact in
            !fact.path.contains("[]") && !operators(for: fact.kind, path: fact.path).isEmpty
        }
    }

    func cel(_ condition: Condition) -> String {
        let kind = RuleCatalog.facts(stage).first { $0.path == condition.fact }?.kind
        let value = condition.value.trimmingCharacters(in: .whitespaces)
        let quoted = RulesConvert.quoted(value)
        let number = Double(value) != nil ? value : "0"
        let f = condition.fact
        switch condition.op {
        case .isTrue: return f
        case .isFalse: return "!\(f)"
        case .equals: return kind == .string ? "\(f) == \(quoted)" : "\(f) == \(number)"
        case .notEquals: return kind == .string ? "\(f) != \(quoted)" : "\(f) != \(number)"
        case .greater: return "\(f) > \(number)"
        case .less: return "\(f) < \(number)"
        case .inList: return "\(f) in lists.\(Self.identifier(value))"
        case .notInList: return "!(\(f) in lists.\(Self.identifier(value)))"
        case .globs: return "glob(\(f), \(quoted))"
        case .contains:
            if case .list = kind { return "\(quoted) in \(f)" }
            return "\(f).contains(\(quoted))"
        case .startsWith: return "\(f).startsWith(\(quoted))"
        case .anyFile: return "touches(\(f), \(quoted))"
        case .everyFile: return "only(\(f), \(quoted))"
        case .longer: return "\(f) > duration(\(RulesConvert.quoted(Self.durationText(value))))"
        case .shorter: return "\(f) < duration(\(RulesConvert.quoted(Self.durationText(value))))"
        }
    }

    var condition: String {
        let parts = conditions.map(cel)
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.map { "(\($0))" }.joined(separator: all ? " && " : " || ")
    }

    var fields: [RuleOutputs.Field] {
        switch stage {
        case .configure: return RuleOutputs.configure
        case .select: return RuleOutputs.select
        case .decide: return RuleOutputs.decide
        }
    }

    var yaml: String {
        let id = RuleExamples.slug(name.isEmpty ? "my-rule" : name)
        var lines = ["name: \(id)", "rule:", "  match:"]
        let condition = self.condition
        if condition.isEmpty {
            lines.append("    - output:")
        } else {
            lines.append("    - condition: '" + condition.replacingOccurrences(of: "'", with: "''") + "'")
            lines.append("      output:")
        }
        let indent = condition.isEmpty ? 8 : 8
        lines.append(String(repeating: " ", count: indent) + "rule: \(id)")
        lines += outputLines(fields.filter { $0.name != "rule" }, prefix: "", indent: indent)
        return lines.joined(separator: "\n") + "\n"
    }

    private func outputLines(_ fields: [RuleOutputs.Field], prefix: String, indent: Int) -> [String] {
        let pad = String(repeating: " ", count: indent)
        var out: [String] = []
        for field in fields {
            let key = prefix + field.name
            if case .object(let inner) = field.kind {
                let nested = outputLines(inner, prefix: key + ".", indent: indent + 2)
                if !nested.isEmpty { out.append(pad + field.name + ":"); out += nested }
                continue
            }
            guard let raw = outputs[key]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { continue }
            switch field.kind {
            case .strings:
                let items = raw.split(separator: ",").map { RulesConvert.yaml($0.trimmingCharacters(in: .whitespaces)) }
                out.append(pad + field.name + ": [" + items.joined(separator: ", ") + "]")
            case .string:
                out.append(pad + field.name + ": " + RulesConvert.quoted(raw))
            default:
                out.append(pad + field.name + ": " + RulesConvert.yaml(raw))
            }
        }
        return out
    }

    static func identifier(_ text: String) -> String {
        let id = String(text.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
        return id.isEmpty ? "trusted" : id
    }

    /// `3 days`, `72h`, `90m` → a CEL duration string.
    static func durationText(_ text: String) -> String {
        let t = text.lowercased().replacingOccurrences(of: " ", with: "")
        if let n = Int(t.filter(\.isNumber)) {
            if t.contains("d") { return "\(n * 24)h" }
            if t.contains("m") { return "\(n)m" }
            if t.contains("s") && !t.contains("h") { return "\(n)s" }
            return "\(n)h"
        }
        return "24h"
    }
}
