import CEL
import CELSwift
import Foundation

/// One stage's rules evaluated on one set of facts, every condition with
/// the values it read: what the Rules tab draws as a tree. The same data
/// `explainSelect` / `explainDecide` print as text, kept as values.
struct RuleTrace: Codable, Sendable, Equatable {
    struct Input: Codable, Sendable, Equatable {
        /// As written, such as `pr.additions`.
        var text: String
        /// Nil when it wasn't evaluated.
        var value: String?
    }

    /// A predicate the condition combines with `&&`, `||`, `!` or `?:`.
    struct Term: Codable, Sendable, Equatable {
        var text: String
        var line: Int?
        var column: Int?
        var value: String?
        var inputs: [Input]
    }

    struct Condition: Codable, Sendable, Equatable {
        /// The policy rule's `id`, when it has one.
        var rule: String?
        var text: String
        var line: Int?
        var column: Int?
        /// The match's output as written; nil for a nested rule.
        var output: String?
        /// Nil when it wasn't evaluated: an earlier match decided.
        var value: String?
        var terms: [Term]

        var holds: Bool? { value.map { $0 == "true" } }
    }

    enum Result: Codable, Sendable, Equatable {
        /// The policy's output, in the words `rules history` uses.
        case matched(String)
        case noMatch
        case error(String)
        /// An earlier policy decided, so this one didn't run.
        case notReached
    }

    struct Policy: Codable, Sendable, Equatable {
        /// The file, as the rules name it in errors and history.
        var path: String
        var conditions: [Condition]
        var result: Result
    }

    var policies: [Policy]
    /// What the facts held for `below`: the answer of the layers underneath.
    var below: String?

    /// The policy that decided, when one did.
    var matched: Policy? {
        policies.first { if case .matched = $0.result { return true }; return false }
    }
}

/// A rule layer's traces for one PR, as `rules.explain` returns them.
struct RuleLayerTrace: Codable, Sendable, Equatable {
    /// "repo" or "personal"; see `RuleLayer`.
    var layer: RuleLayer
    /// Where its rules come from, for a heading.
    var source: String
    var select: RuleTrace?
    var decide: RuleTrace?
}

extension Rules {
    func traceSelect(_ facts: SelectFacts) -> RuleTrace {
        var trace = Self.trace(select, facts, paths: sources.prefix(select.count).map(\.path)) { Self.describe($0) }
        trace.below = facts.below.map(Self.describe)
        return trace
    }

    func traceDecide(_ facts: DecideFacts) -> RuleTrace {
        var trace: RuleTrace
        if let failure {
            trace = RuleTrace(policies: [RuleTrace.Policy(path: "", conditions: [], result: .error(failure))])
        } else {
            trace = Self.trace(decide, facts, paths: sources.dropFirst(select.count).prefix(decide.count).map(\.path)) { Self.describe($0) }
        }
        trace.below = facts.below.map(Self.describe)
        return trace
    }

    static func describe(_ below: BelowFacts) -> String {
        var text = below.action
        if !below.rule.isEmpty { text = "\(below.rule): \(text)" }
        if !below.reason.isEmpty { text += " (\(below.reason))" }
        return "\(text), from \(below.source)"
    }

    private static func trace<F, O>(
        _ programs: [TypedProgram<F, O?>], _ facts: F, paths: [String], describe: (O) -> String
    ) -> RuleTrace {
        var policies: [RuleTrace.Policy] = []
        var decided = false
        for (index, program) in programs.enumerated() {
            let path = index < paths.count ? paths[index] : ""
            guard !decided else {
                policies.append(RuleTrace.Policy(path: path, conditions: [], result: .notReached))
                continue
            }
            let explanation: Explanation<O?>
            do {
                explanation = try program.explain(facts)
            } catch {
                policies.append(RuleTrace.Policy(path: path, conditions: [], result: .error(String(describing: error))))
                decided = true
                continue
            }
            let result: RuleTrace.Result
            switch explanation.result {
            case .success(let output?):
                result = .matched(describe(output))
                decided = true
            case .success(nil):
                result = .noMatch
            case .failure(let error):
                result = .error(error.message)
                decided = true
            }
            policies.append(RuleTrace.Policy(
                path: path, conditions: explanation.conditions.map(condition), result: result))
        }
        return RuleTrace(policies: policies)
    }

    private static func condition<O>(_ condition: Explanation<O>.Condition) -> RuleTrace.Condition {
        RuleTrace.Condition(
            rule: condition.ruleID, text: condition.text, line: condition.line, column: condition.column,
            output: condition.output, value: condition.value.map { "\($0)" },
            terms: condition.terms.map { term in
                RuleTrace.Term(
                    text: term.text, line: term.line, column: term.column, value: term.value.map { "\($0)" },
                    inputs: term.inputs.map { RuleTrace.Input(text: $0.text, value: $0.value.map { "\($0)" }) })
            })
    }
}
