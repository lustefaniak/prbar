import CEL
import CELPolicy
import CELSwift
import Foundation

/// The `select` policy's output.
struct RuleSelection: Codable, Sendable, Hashable, CELNamedType {
    static let celTypeName = "prbar.Selection"

    enum Action: String, Codable, Sendable, Hashable, CaseIterable {
        case review
        case skip
    }

    /// The rule's id, for History and the explain trace.
    var rule: String
    var action: Action
    /// Shown with a skip.
    var reason: String?
}

/// The `decide` policy's output: what PRBar posts on its own.
struct RuleDecision: Codable, Sendable, Hashable, CELNamedType {
    static let celTypeName = "prbar.Decision"

    enum Action: String, Codable, Sendable, Hashable, CaseIterable {
        /// A GitHub approval.
        case approve
        /// A GitHub "request changes" review, the summary as its body.
        case requestChanges = "request_changes"
        /// A comment review with the summary, no verdict.
        case comment
        /// The findings as inline comments, no verdict, and the review
        /// request restored so the next push is reviewed again.
        case share
        /// Shown in PRBar, nothing posted.
        case flag
        /// Nothing posted.
        case none
    }

    var rule: String
    var action: Action
    /// Post the findings as inline comments. Defaults: off for approve,
    /// on for everything else.
    var inline: Bool?
    /// Only findings at or above this severity go inline.
    var minSeverity: AnnotationSeverity?
    /// At most this many inline comments, highest severities first.
    /// Defaults: 20 for share, no cap otherwise.
    var maxComments: Int?
    /// Approve with a one-line body naming PRBar and the confidence.
    var attribution: Bool?
}

/// The compiled rules directory (`RuleDirectory`): CEL policies per stage,
/// in the format of cel-go's policies (`rule.match[].condition` / `output`,
/// first match wins). The files of a stage run in order and the first that
/// matches decides. When none does, the repo settings in prbar.yaml decide
/// as they always have, so rules can take over one case at a time.
///
/// Compiled when they load, so a misspelt fact, a fact the stage doesn't
/// have or an output of the wrong shape refuses them, with file, line and
/// column, instead of failing on a PR later.
struct Rules: Sendable {
    struct Source: Sendable, Hashable {
        var path: String
        var text: String
    }

    let select: [TypedProgram<SelectFacts, RuleSelection?>]
    let decide: [TypedProgram<DecideFacts, RuleDecision?>]
    let lists: [String: [String]]
    let sources: [Source]
    /// Set when the rules didn't compile at launch, with nothing earlier to
    /// keep. Nothing is posted on its own until they do: `decide` answers
    /// `none` for every review.
    let failure: String?

    static let coding = CELCodingOptions(keyStrategy: .convertToSnakeCase)

    /// Every evaluation is bounded: rules can come from someone else's
    /// file, and a rule that runs out of budget decides nothing.
    static let programOptions: [Program.Option] = [.costLimit(1_000_000), .timeLimit(.seconds(1))]

    static func environment() throws -> Environment {
        try Environment(
            .enumConstants(AnnotationSeverity.self, namespace: "severity", options: coding),
            .function("glob", .overload("glob_string_string") { (value: String, pattern: String) in
                GlobMatcher.match(pattern, value)
            })
        )
    }

    /// - Throws: `ValidationError` with every problem, positioned in its file.
    static func compile(select: [Source], decide: [Source], lists: [String: [String]] = [:]) throws -> Rules {
        let env = try environment()
        func load<F, O>(_ source: Source) throws -> TypedProgram<F, O?> {
            try TypedProgram<F, O?>(
                policy: PolicySource(source.text, description: source.path), environment: env,
                options: coding, programOptions: programOptions)
        }
        return Rules(
            select: try select.map(load), decide: try decide.map(load), lists: lists,
            sources: select + decide, failure: nil)
    }

    static func unloaded(_ reason: String) -> Rules {
        Rules(select: [], decide: [], lists: [:], sources: [], failure: reason)
    }

    static let unloadedRuleID = "rules-not-loaded"
    /// The id a decision carries when evaluating the rules failed.
    static let errorRuleID = "rule-error"

    /// Nil when no select policy matches.
    func select(_ facts: SelectFacts) throws -> RuleSelection? {
        for program in select {
            if let selection = try program.evaluate(facts) { return selection }
        }
        return nil
    }

    /// Nil when no decide policy matches.
    func decide(_ facts: DecideFacts) throws -> RuleDecision? {
        if failure != nil { return RuleDecision(rule: Self.unloadedRuleID, action: .none) }
        for program in decide {
            if let decision = try program.evaluate(facts) { return decision }
        }
        return nil
    }
}

extension Rules {
    /// Why the select stage decides what it does: every condition of
    /// each policy, in order, up to the one that matched.
    func explainSelect(_ facts: SelectFacts) -> String {
        Self.explain(select, facts, sources: sources, stage: "select", fallback: "the repo settings in prbar.yaml decide")
    }

    func explainDecide(_ facts: DecideFacts) -> String {
        if let failure { return "The rules didn't load, so nothing is posted on its own:\n\(failure)" }
        return Self.explain(decide, facts, sources: sources, stage: "decide", fallback: "the repo settings in prbar.yaml decide")
    }

    private static func explain<F, O>(
        _ programs: [TypedProgram<F, O?>], _ facts: F, sources: [Source], stage: String, fallback: String
    ) -> String {
        guard !programs.isEmpty else { return "No \(stage) rules; \(fallback)." }
        var blocks: [String] = []
        for program in programs {
            let explanation: Explanation<O?>
            do {
                explanation = try program.explain(facts)
            } catch {
                blocks.append("error: \(error)")
                return blocks.joined(separator: "\n\n")
            }
            var text = explanation.conditions.isEmpty ? "" : String(describing: explanation).components(separatedBy: "\n").dropLast().joined(separator: "\n")
            switch explanation.result {
            case .success(let output?):
                text += (text.isEmpty ? "" : "\n") + "matched: \(describe(output))"
                blocks.append(text)
                return blocks.joined(separator: "\n\n")
            case .success(nil):
                text += (text.isEmpty ? "" : "\n") + "no match"
            case .failure(let error):
                text += (text.isEmpty ? "" : "\n") + "error: \(error.message)"
                blocks.append(text)
                return blocks.joined(separator: "\n\n")
            }
            blocks.append(text)
        }
        blocks.append("No \(stage) rule matched; \(fallback).")
        return blocks.joined(separator: "\n\n")
    }

    private static func describe(_ output: Any) -> String {
        switch output {
        case let selection as RuleSelection:
            return "\(selection.rule): \(selection.action.rawValue)\(selection.reason.map { " (\($0))" } ?? "")"
        case let decision as RuleDecision:
            var parts = [decision.action.rawValue]
            if let inline = decision.inline { parts.append("inline \(inline)") }
            if let floor = decision.minSeverity { parts.append("from \(floor.rawValue)") }
            if let cap = decision.maxComments { parts.append("at most \(cap)") }
            if decision.attribution == true { parts.append("with attribution") }
            return "\(decision.rule): \(parts.joined(separator: ", "))"
        default:
            return String(describing: output)
        }
    }
}

extension Rules: Hashable {
    static func == (lhs: Rules, rhs: Rules) -> Bool {
        lhs.sources == rhs.sources && lhs.lists == rhs.lists && lhs.failure == rhs.failure
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(sources)
        hasher.combine(lists)
        hasher.combine(failure)
    }
}
