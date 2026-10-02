import Foundation

/// Where a draft of rules comes from, for the CLI and the MCP tools alike:
/// files on disk the client reads and sends, so the server never reads a
/// path a client names.
struct RuleDraftSource: Equatable, Sendable {
    /// Rule files laid over the user's rules, by their paths in this
    /// directory (`decide/50-x.yaml`, `lists.yaml`).
    var dir: String?
    /// The user's rule files the draft deletes, relative to the rules
    /// directory.
    var remove: [String] = []
    /// Instead: a repository's rules, as `.prbar/rules` or the checkout
    /// holding it, standing in for what its default branch has.
    var repoRules: String?
    /// `owner/name` of that repository; read from the checkout's `origin`
    /// when not given.
    var repository: String?

    var isEmpty: Bool { dir == nil && remove.isEmpty && repoRules == nil }

    enum Failure: Error, LocalizedError, Equatable {
        case notADirectory(String)
        case both
        case unknownRepository(String)

        var errorDescription: String? {
            switch self {
            case .notADirectory(let path): return "\(path) isn't a directory"
            case .both: return "pass a draft of your rules or a repository's rules, not both"
            case .unknownRepository(let path):
                return "can't tell which repository \(path) belongs to: its checkout has no GitHub origin. Say it with --repo owner/name (MCP: repository)."
            }
        }
    }

    func load() async throws -> RuleDraft {
        if let repoRules {
            guard dir == nil, remove.isEmpty else { throw Failure.both }
            var root = URL(fileURLWithPath: (repoRules as NSString).expandingTildeInPath).standardizedFileURL
            let nested = root.appendingPathComponent(".prbar/rules")
            if Self.isDirectory(nested) { root = nested }
            guard Self.isDirectory(root) else { throw Failure.notADirectory(root.path) }
            var repository = repository
            if repository == nil, let checkout = try? await LocalChanges.root(of: root.path),
               let origin = try? await LocalChanges.git(["remote", "get-url", "origin"], in: URL(fileURLWithPath: checkout)),
               let slug = LocalChanges.gitHubSlug(origin) {
                repository = "\(slug.owner)/\(slug.repo)"
            }
            guard let repository else { throw Failure.unknownRepository(root.path) }
            return RuleDraft(files: try RuleDirectory.read(root), layer: .repo, repository: repository)
        }
        var draft = RuleDraft(removed: remove)
        if let dir {
            let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).standardizedFileURL
            guard Self.isDirectory(url) else { throw Failure.notADirectory(url.path) }
            draft.files = try RuleDirectory.read(url)
        }
        return draft
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}

/// What the rule-authoring commands and tools say, the same on both: counts
/// first, a definite empty state, long lists cut short behind `full`, and
/// a `Next:` line.
enum RulesText {
    static let listLimit = 20

    static func catalog(_ catalog: RuleCatalogResult, example: String? = nil) -> String {
        if let example {
            guard let found = catalog.examples.first(where: { $0.id == example }) else {
                return "No example \(example). Examples: \(catalog.examples.map(\.id).joined(separator: ", "))."
            }
            var out = "\(found.title) (\(found.stage)): \(found.detail)\n\n# \(found.path)\n\(found.text)"
            if let lists = found.lists {
                out += "\n# lists.yaml needs\n" + lists.keys.sorted().map { "\($0): [\((lists[$0] ?? []).joined(separator: ", "))]" }.joined(separator: "\n") + "\n"
            }
            return out
        }
        var lines: [String] = []
        if catalog.stages.count > 1 {
            lines.append("Rules have three stages, each a directory of .yaml policies checked in name order; the first match decides, and no match leaves the decision to the layer below (`below`):")
            for stage in catalog.stages {
                lines.append("- \(stage.stage): \(stageHelp(stage.stage)) \(stage.facts.count) facts, \(stage.outputs.count) output fields.")
            }
            lines.append("")
        }
        for stage in catalog.stages where catalog.stages.count == 1 {
            lines.append("Facts in \(stage.stage) (\(stage.facts.count)):")
            lines += stage.facts.map { "  \($0.path)  \($0.type)  \($0.help)" }
            lines.append("")
            lines.append("Output fields of \(stage.stage) (\(stage.outputs.count)), written as plain YAML under `output:`:")
            lines += stage.outputs.map { output in
                var line = "  \(output.name)\(output.required ? " (required)" : "")  \(output.type)  \(output.help)"
                if let values = output.values {
                    line += " Values: " + values.keys.sorted().map { key in
                        let help = values[key] ?? ""
                        return help.isEmpty ? key : "\(key) (\(help))"
                    }.joined(separator: "; ")
                }
                return line
            }
            lines.append("")
        }
        lines.append("Functions and constants (\(catalog.functions.count)):")
        lines += catalog.functions.map { "  \($0.signature)  \($0.help)" }
        lines.append("")
        lines.append("Your lists: " + (catalog.lists.isEmpty ? "none yet (lists.yaml: `name: [login, ...]`)." : catalog.lists.map { "lists.\($0)" }.joined(separator: ", ")))
        lines.append("")
        lines.append("Examples (\(catalog.examples.count)):")
        lines += catalog.examples.map { "  \($0.id)  \($0.stage)/  \($0.title)" }
        lines.append("")
        lines.append(catalog.stages.count > 1
            ? "Next: the catalog of one stage for its facts and output fields; an example by id for its text."
            : "Next: an example by id for its text; check the draft once written.")
        return lines.joined(separator: "\n")
    }

    static func stageHelp(_ stage: String) -> String {
        switch stage {
        case "configure": return "per-repository settings (models, budgets, gates); sees only the repository."
        case "select": return "whether a PR is reviewed at all."
        case "decide": return "what is posted once a review is in."
        default: return ""
        }
    }

    static func check(_ result: CheckRulesResult, draft: RuleDraft) -> String {
        let whose = draft.isRepository ? "\(draft.repository ?? "the repository")'s rules" : "Your rules with the draft"
        var lines: [String] = []
        if let problem = result.problem {
            lines.append("\(whose) don't compile:")
            lines.append(problem)
        } else {
            lines.append("\(whose) compile.")
        }
        func names(_ files: [String]) -> String { files.isEmpty ? "none" : files.joined(separator: ", ") }
        lines.append("select: \(names(result.select))")
        lines.append("decide: \(names(result.decide))")
        lines.append("configure: \(names(result.configure))")
        lines.append("lists: " + (result.lists.isEmpty ? "none" : result.lists.keys.sorted().map { "\($0) (\(result.lists[$0] ?? 0))" }.joined(separator: ", ")))
        lines += result.notes.map { "Note: \($0)" }
        lines.append("")
        lines.append(result.problem == nil
            ? "Next: explain on a PR to see what the rules decide for it, impact to see which recorded decisions they change."
            : "Next: fix the file at the line and column given, then check again.")
        return lines.joined(separator: "\n")
    }

    static func impact(_ impact: RuleImpact, draft: RuleDraft, days: Int?, full: Bool) -> String {
        if let problem = impact.draftProblem {
            return "The draft doesn't compile, so nothing was replayed:\n\(problem)\n\nNext: fix it, then check again."
        }
        let span = days.map { "the last \($0) day\($0 == 1 ? "" : "s")" } ?? "every kept record"
        let subject = draft.isRepository ? "\(draft.repository ?? "the repository")'s rules" : "the draft"
        guard impact.examined > 0 else {
            return "No recorded decisions in \(span)\(draft.isRepository ? " for \(draft.repository ?? "that repository")" : "") to replay. PRBar records one each time it decides whether to review a PR, and what to post once reviewed."
        }
        let decided = impact.decided
        var lines = ["Replayed \(impact.examined) recorded decision\(impact.examined == 1 ? "" : "s") from \(span) with \(subject): \(decided.isEmpty ? "no answer changes." : "\(decided.count) change\(decided.count == 1 ? "s" : "").")"]
        let undecided = impact.undecided
        if !undecided.isEmpty {
            let needs = Set(undecided.compactMap { change -> String? in
                guard let range = change.draft.range(of: "needs ") else { return nil }
                return change.draft[range.upperBound...].components(separatedBy: ", which").first
            })
            lines.append("\(undecided.count) more can't tell: they were recorded before \(needs.sorted().joined(separator: ", ")) was fetched for them. explain on a PR fetches it now: \(undecided.prefix(3).map(\.record.pr).joined(separator: ", ")).")
        }
        if draft.isRepository, !decided.isEmpty {
            lines.append("Each line is what the repository's rules would answer; your own rules still apply above them.")
        }
        let shown = full ? decided : Array(decided.prefix(listLimit))
        for change in shown {
            lines.append("")
            lines.append("\(change.record.pr)  \(change.record.stage.rawValue)  \(change.record.title)")
            lines.append("    now:   \(change.now)")
            lines.append("    draft: \(change.draft)")
        }
        if shown.count < decided.count {
            lines.append("")
            lines.append("\(decided.count - shown.count) more not shown; ask with full for all of them.")
        }
        lines.append("")
        lines.append(draft.isRepository
            ? "Next: put the changes in the PR to the repository's .prbar/rules, with this list in its description."
            : "Next: propose the draft for the user to accept.")
        return lines.joined(separator: "\n")
    }

    static func proposed(_ result: ProposeRulesResult) -> String {
        let p = result.proposal
        var lines = [result.applied
            ? "Saved \(files(p.draft)) to the user's rules (agents.rules is allow)."
            : "Proposed \(short(p.id)) \"\(p.title)\": \(files(p.draft)), waiting for the user."]
        if let impact = p.impact {
            lines.append("It \(impact.sentence(days: 30)).")
        }
        lines.append("")
        lines.append(result.applied
            ? "Next: explain on a PR to see the rules at work."
            : "Next: tell the user to accept it in PRBar's Settings → Rules, or with `prbar-review rules accept \(short(p.id))`.")
        return lines.joined(separator: "\n")
    }

    static func proposals(_ proposals: [RuleProposal], now: Date = Date()) -> String {
        guard !proposals.isEmpty else { return "No rule proposals are waiting." }
        var lines = ["\(proposals.count) rule proposal\(proposals.count == 1 ? "" : "s") waiting for the user:"]
        for p in proposals {
            lines.append("")
            lines.append("\(short(p.id))  \(p.title)  (by \(p.by), \(RulesCommand.timestamp(p.at)))")
            lines.append("    \(files(p.draft))")
            if !p.why.isEmpty { lines.append("    why: \(p.why)") }
            if let impact = p.impact {
                lines.append("    \(impact.sentence(days: 30))")
            }
        }
        lines.append("")
        lines.append("Next: prbar-review rules accept <id> or reject <id>; Settings → Rules shows each with its files.")
        return lines.joined(separator: "\n")
    }

    static func files(_ draft: RuleDraft) -> String { draft.summary }

    static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }

    static func explanation(_ explanation: RulesExplanation, draft: RuleDraft?) -> String {
        var out = ""
        if let problem = explanation.draftProblem {
            out += "The draft doesn't compile, so this is the rules in effect:\n\(problem)\n\n"
        } else if let draft, draft.isRepository {
            out += "With \(draft.repository ?? "the repository")'s rules from the draft, as if trusted.\n\n"
        } else if draft != nil {
            out += "With the draft laid over your rules.\n\n"
        }
        return out + RulesCommand.describe(explanation)
    }
}
