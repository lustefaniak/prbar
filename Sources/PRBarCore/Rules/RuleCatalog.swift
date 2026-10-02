import CEL
import CELSwift
import Foundation

/// What a rule can read, per stage: every fact with its type and what it
/// means, and the functions. The fact names and types come from the same
/// schema the rules are checked against, so completion, the facts panel
/// and the builder can't offer something that fails to compile; only the
/// descriptions are written by hand (`RuleCatalog.help`), and a test
/// checks every fact has one.
enum RuleCatalog {
    enum Stage: String, CaseIterable, Sendable {
        case configure, select, decide

        init?(path: String) {
            guard let stage = path.split(separator: "/").first.flatMap({ Stage(rawValue: String($0)) }) else { return nil }
            self = stage
        }
    }

    enum Kind: Hashable, Sendable {
        case bool, int, double, string, duration, timestamp
        /// A list of these; `element` names the fields of an object element.
        case list(element: String)
        case map
        /// Has fields of its own, under `path.`.
        case object
        case other
    }

    struct Fact: Hashable, Sendable, Identifiable {
        /// As written in a condition: `pr.additions`. Fields of a list's
        /// elements are under `pr.files[]`, written `f.path` inside
        /// `pr.files.exists(f, f.path ...)`.
        var path: String
        var type: String
        var kind: Kind
        var help: String

        var id: String { path }
        /// The last name of the path: `additions`.
        var name: String { path.split(separator: ".").last.map(String.init) ?? path }
        /// Where the fact sits: `pr` for `pr.additions`, `pr.files[]` for its elements' fields.
        var parent: String {
            guard let dot = path.lastIndex(of: ".") else { return "" }
            return String(path[..<dot])
        }
    }

    struct Function: Hashable, Sendable, Identifiable {
        var name: String
        var signature: String
        /// Called on a value (`pr.title.contains(...)`), not on its own.
        var isMethod: Bool { signature.hasPrefix("text.") || signature.hasPrefix("list.") }
        var help: String
        /// What is inserted, `$0` where the cursor goes.
        var template: String
        var id: String { signature }
    }

    static func facts(_ stage: Stage) -> [Fact] {
        cache.value(stage)
    }

    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Stage: [Fact]] = [:]

        func value(_ stage: Stage) -> [Fact] {
            lock.lock()
            defer { lock.unlock() }
            if let facts = stored[stage] { return facts }
            let facts = RuleCatalog.derive(stage)
            stored[stage] = facts
            return facts
        }
    }

    private static func derive(_ stage: Stage) -> [Fact] {
        let schema: CELSchema?
        switch stage {
        case .configure: schema = try? CELSchema(for: ConfigureFacts.self, options: Rules.coding)
        case .select: schema = try? CELSchema(for: SelectFacts.self, options: Rules.coding)
        case .decide: schema = try? CELSchema(for: DecideFacts.self, options: Rules.coding)
        }
        guard let schema, let fields = schema.fields else { return [] }
        var out: [Fact] = []
        func walk(_ fields: [CELSchema.Field], prefix: String, depth: Int) {
            for field in fields {
                let path = prefix.isEmpty ? field.name : "\(prefix).\(field.name)"
                let (kind, type, object) = describe(field.type, in: schema)
                out.append(Fact(path: path, type: type, kind: kind, help: help[path] ?? ""))
                guard depth < 4, let object, let fields = schema.structType(named: object)?.fields else { continue }
                if case .list = kind {
                    walk(fields, prefix: path + "[]", depth: depth + 1)
                } else {
                    walk(fields, prefix: path, depth: depth + 1)
                }
            }
        }
        walk(fields, prefix: "", depth: 0)
        return out
    }

    /// The kind, a readable type, and the object type whose fields follow.
    private static func describe(_ type: CELType, in schema: CELSchema) -> (Kind, String, String?) {
        switch type {
        case .bool: return (.bool, "bool", nil)
        case .int, .uint: return (.int, "int", nil)
        case .double: return (.double, "double", nil)
        case .string: return (.string, "string", nil)
        case .duration: return (.duration, "duration", nil)
        case .timestamp: return (.timestamp, "timestamp", nil)
        case .map: return (.map, "map", nil)
        case .object(let name): return (.object, name, name)
        case .list(let element):
            let (_, inner, object) = describe(element, in: schema)
            return (.list(element: object ?? inner), "list of \(inner)", object)
        case .opaque(name: _, parameters: let parameters) where parameters.count == 1:
            let (kind, inner, object) = describe(parameters[0], in: schema)
            return (kind, inner + ", or null", object)
        default:
            return (.other, "\(type)", nil)
        }
    }

    static let functions: [Function] = [
        Function(name: "touches", signature: "touches(pr.files, \"glob\")", help: "Whether any changed file matches the pattern. False when the files couldn't be read.", template: "touches(pr.files, \"$0\")"),
        Function(name: "only", signature: "only(pr.files, \"glob\")", help: "Whether every changed file matches the pattern, and there is at least one.", template: "only(pr.files, \"$0\")"),
        Function(name: "glob", signature: "glob(value, \"pattern\" or list)", help: "Whether a string matches a glob, or any of a list of globs (later ones winning, `!` excluding).", template: "glob($0, \"\")"),
        Function(name: "matches", signature: "text.matches(\"regex\")", help: "Whether the text matches a regular expression (RE2).", template: "matches(\"$0\")"),
        Function(name: "contains", signature: "text.contains(\"part\")", help: "Whether the text contains the part.", template: "contains(\"$0\")"),
        Function(name: "startsWith", signature: "text.startsWith(\"prefix\")", help: "Whether the text starts with the prefix.", template: "startsWith(\"$0\")"),
        Function(name: "endsWith", signature: "text.endsWith(\"suffix\")", help: "Whether the text ends with the suffix.", template: "endsWith(\"$0\")"),
        Function(name: "size", signature: "list.size()", help: "How many items a list has, or characters a string.", template: "size()$0"),
        Function(name: "exists", signature: "list.exists(x, condition)", help: "Whether any item satisfies the condition.", template: "exists(x, $0)"),
        Function(name: "all", signature: "list.all(x, condition)", help: "Whether every item satisfies the condition.", template: "all(x, $0)"),
        Function(name: "filter", signature: "list.filter(x, condition)", help: "The items that satisfy the condition.", template: "filter(x, $0)"),
        Function(name: "map", signature: "list.map(x, expression)", help: "Each item transformed.", template: "map(x, $0)"),
        Function(name: "has", signature: "has(pr.field)", help: "Whether a field is set: false for a fact that couldn't be fetched.", template: "has($0)"),
        Function(name: "duration", signature: "duration(\"2h\")", help: "A duration to compare with `pr.age` or `pr.idle`: `h`, `m`, `s`.", template: "duration(\"$0\")"),
        Function(name: "lowerAscii", signature: "text.lowerAscii()", help: "The text in lower case.", template: "lowerAscii()$0"),
    ]

    /// Severity constants, compared by rank: `review.max_severity >= severity.warning`.
    static let constants = AnnotationSeverity.allCases.map { "severity.\($0.rawValue)" }
}

extension RuleCatalog {
    static let help: [String: String] = [
        "repo": "The repository whose settings are being decided.",
        "repo.full_name": "`owner/name`.",
        "repo.owner": "The owner (user or organisation).",
        "repo.name": "The repository's name, without the owner.",
        "lists": "Your lists from rules/lists.yaml: `pr.author in lists.trusted`.",
        "now": "When the rule runs.",
        "viewer": "Your GitHub login.",
        "trigger": "Why it is considered: `review_requested`, `command` (prbar-review <pr>) or `agent` (MCP).",
        "below": "What the layers under this rule would decide: the settings, or the repository's rules.",
        "below.action": "select: `review` or `skip`. decide: `approve`, `request_changes`, `comment`, `share`, `flag` or `none`.",
        "below.reason": "Why, in words, when there is a reason.",
        "below.rule": "The id of the rule that decided; empty when the settings did.",
        "below.source": "`settings`, or `repo` when the repository's rules decided.",
        "pr": "The pull request.",
        "pr.repo": "`owner/name`.",
        "pr.owner": "The repository's owner.",
        "pr.name": "The repository's name.",
        "pr.number": "0 for a local review.",
        "pr.title": "The title.",
        "pr.body": "The description.",
        "pr.author": "The author's login.",
        "pr.author_association": "GitHub's: OWNER, MEMBER, COLLABORATOR, CONTRIBUTOR, FIRST_TIME_CONTRIBUTOR, FIRST_TIMER, NONE.",
        "pr.author_is_bot": "A GitHub App or a [bot] account.",
        "pr.labels": "Label names.",
        "pr.base_ref": "The branch it merges into.",
        "pr.head_ref": "Its branch.",
        "pr.draft": "Whether it is a draft.",
        "pr.additions": "Lines added.",
        "pr.deletions": "Lines deleted.",
        "pr.changed_files": "How many files changed.",
        "pr.created_at": "When it was opened.",
        "pr.updated_at": "When it last changed.",
        "pr.head_committed_at": "When its head commit was made.",
        "pr.age": "How long since it was opened: `pr.age > duration(\"72h\")`.",
        "pr.idle": "How long since it last changed.",
        "pr.requested": "You are a requested reviewer.",
        "pr.authored": "You opened it.",
        "pr.requested_reviewers": "Logins with a pending review request.",
        "pr.requested_teams": "Team slugs with a pending review request.",
        "pr.reviews": "People's reviews.",
        "pr.reviews[].author": "The reviewer's login.",
        "pr.reviews[].state": "`approved`, `changes_requested`, `commented` or `dismissed`.",
        "pr.reviews[].submitted_at": "When it was submitted.",
        "pr.reviews[].by_viewer": "You wrote it.",
        "pr.reviewed_by_others": "Another person approved or requested changes.",
        "pr.prbar_verdict_at_head": "Some PRBar already posted a verdict for this commit.",
        "pr.checks_state": "`passed`, `failed`, `pending`, or `none` with no checks.",
        "pr.checks": "CI checks.",
        "pr.checks[].name": "The check's name.",
        "pr.checks[].state": "`passed`, `failed`, `pending` or `unknown`.",
        "pr.files": "The changed files, from the diff. Fetched only when a rule needs them; null when that failed. Use touches() and only().",
        "pr.files[].path": "The file's path.",
        "pr.files[].additions": "Lines added.",
        "pr.files[].deletions": "Lines deleted.",
        "pr.files[].kind": "`source`, `test`, `manifest`, `generated` or `docs`.",
        "pr.files[].sensitive": "The path names an area like auth, secrets, tokens, crypto or permissions.",
        "pr.files[].risk": "0 to 1: size, source without its test, a sensitive area.",
        "pr.committers": "Everyone who authored or committed a commit, by login. Fetched only when a rule needs it.",
        "pr.codeowners": "Every changed file with its code owners from CODEOWNERS on the base branch. Fetched only when a rule needs it. `pr.codeowners.all(f, pr.author in f.owners)`: the author owns every file.",
        "pr.codeowners[].path": "The changed file.",
        "pr.codeowners[].owners": "Logins that own it: the users the deciding CODEOWNERS line names, and the members of its teams. Empty when no line owns it.",
        "pr.codeowners[].teams": "The teams that line names, `org/team`.",
        "pr.codeowners[].pattern": "The deciding line's pattern; null when no line matched.",
        "pr.local": "A local review (prbar-review <dir>), not a pull request.",
        "review": "The review's result (decide only).",
        "review.verdict": "`approve`, `comment` (approve with notes), `request_changes` or `abstain`.",
        "review.confidence": "0 to 1.",
        "review.provider": "`claude` or `codex`.",
        "review.findings": "The findings.",
        "review.findings[].path": "The file.",
        "review.findings[].line_start": "First line.",
        "review.findings[].line_end": "Last line.",
        "review.findings[].severity": "Compare with severity.info, .suggestion, .warning, .blocker.",
        "review.findings[].title": "The finding's title.",
        "review.findings[].body": "The finding's text.",
        "review.max_severity": "The worst finding's severity; severity.info with none.",
        "review.cost_usd": "What the review cost.",
        "review.subreviews": "Per monorepo folder.",
        "review.subreviews[].path": "The folder; empty for the root.",
        "review.subreviews[].verdict": "That folder's verdict.",
        "review.subreviews[].confidence": "That folder's confidence.",
        "review.subreviews[].findings": "How many findings.",
        "review.prior": "Reviews of earlier commits of this PR that were never posted, oldest first.",
        "review.prior[].head_sha": "The commit.",
        "review.prior[].verdict": "That review's verdict.",
        "review.prior[].confidence": "That review's confidence.",
        "review.prior[].findings": "How many findings.",
        "review.prior[].max_severity": "The worst finding's severity.",
    ]
}
