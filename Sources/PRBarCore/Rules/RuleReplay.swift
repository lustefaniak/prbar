import Foundation

/// Recorded evaluations against the rules as they are now: what changes
/// when a rule is edited, before it decides anything live.
enum RuleReplay {
    struct Result: Sendable {
        var evaluation: RuleEvaluation
        /// The answer now, in the same words as `evaluation.outcome`.
        var outcome: String
        var rule: String?
        /// Lazy facts the rules now read that weren't fetched when it was
        /// recorded; the answer is undecided without them.
        var missing: Set<LazyFact>
        var error: String?

        var changed: Bool { outcome != evaluation.outcome }
    }

    static func replay(_ evaluation: RuleEvaluation, rules: Rules?) -> Result {
        var result = Result(evaluation: evaluation, outcome: "", rule: nil, missing: [], error: nil)
        var pending = Set(LazyFact.allCases).subtracting(evaluation.fetched)
        do {
            switch evaluation.stage {
            case .select:
                guard var facts = evaluation.select else { throw ReplayError.noFacts }
                guard let rules else { result.outcome = Rules.describe(nil as RuleSelection?); return result }
                facts.lists = rules.lists
                switch try rules.select(facts, pending: pending) {
                case .decided(let selection):
                    result.outcome = Rules.describe(selection)
                    result.rule = selection?.rule
                case .needs(let facts):
                    result.missing = facts
                    result.outcome = undecided(facts)
                }
            case .decide:
                guard var facts = evaluation.decide else { throw ReplayError.noFacts }
                guard let rules else { result.outcome = Rules.describe(nil as RuleDecision?); return result }
                facts.lists = rules.lists
                // The files came from the diff the review read.
                pending.remove(.files)
                switch try rules.decide(facts, pending: pending) {
                case .decided(let decision):
                    result.outcome = Rules.describe(decision)
                    result.rule = decision?.rule
                case .needs(let facts):
                    result.missing = facts
                    result.outcome = undecided(facts)
                }
            }
        } catch {
            result.error = String(describing: error)
            result.outcome = "error: \(error)"
        }
        return result
    }

    /// Every condition with the recorded facts, as `rules explain` shows it.
    static func explain(_ evaluation: RuleEvaluation, rules: Rules?) -> String {
        guard let rules else { return "No rules; the settings in prbar.yaml decide." }
        switch evaluation.stage {
        case .select:
            guard var facts = evaluation.select else { return "The record holds no facts." }
            facts.lists = rules.lists
            return rules.explainSelect(facts)
        case .decide:
            guard var facts = evaluation.decide else { return "The record holds no facts." }
            facts.lists = rules.lists
            return rules.explainDecide(facts)
        }
    }

    private static func undecided(_ facts: Set<LazyFact>) -> String {
        "undecided: needs \(facts.map { "pr.\($0.rawValue)" }.sorted().joined(separator: ", ")), which this snapshot doesn't have"
    }

    enum ReplayError: Error, CustomStringConvertible {
        case noFacts
        var description: String { "the record holds no facts" }
    }
}
