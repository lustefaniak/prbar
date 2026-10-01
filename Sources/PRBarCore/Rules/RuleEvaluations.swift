import Foundation

/// One evaluation of a rule stage, with the exact facts the rules saw, so
/// it can be replayed later against edited rules: `prbar-review rules
/// replay`. Written to `history/rules/YYYY-MM.jsonl`.
struct RuleEvaluation: Codable, Sendable, Identifiable, Hashable {
    enum Stage: String, Codable, Sendable, Hashable {
        case select, decide
    }

    var id: UUID
    var at: Date
    var stage: Stage
    var repo: String
    var number: Int
    var title: String
    var headSha: String
    /// The facts, as the rules saw them; one of the two, by `stage`.
    var select: SelectFacts?
    var decide: DecideFacts?
    /// The matched rule's id, nil when none matched and the settings decided.
    var rule: String?
    /// What the rules answered, in words: `skip-docs: skip (docs only)`.
    var outcome: String
    /// Which rules produced it: a digest of every policy file and the
    /// lists, so a replay can say whether the rules changed since.
    var rulesDigest: String
    /// The policy files in effect, by path.
    var ruleFiles: [String]
    /// The lazy facts fetched for it. One a replayed rule now needs that
    /// isn't here was never fetched, so the replay says so.
    var fetched: [LazyFact]

    var pr: String { number == 0 ? repo : "\(repo)#\(number)" }
}

extension Rules {
    /// Identifies the rules' contents: equal digests, equal rules. FNV-1a,
    /// since it only tells versions apart and must build on Linux too.
    static func digest(_ sources: [Source], lists: [String: [String]]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ text: String) {
            for byte in text.utf8 + [0] {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
        }
        for source in sources {
            mix(source.path)
            mix(source.text)
        }
        for key in lists.keys.sorted() {
            mix(key)
            (lists[key] ?? []).forEach(mix)
        }
        return String(hash, radix: 16)
    }

    static func describe(_ selection: RuleSelection?) -> String {
        guard let selection else { return "no rule matched; the settings decide" }
        return "\(selection.rule): \(selection.action.rawValue)\(selection.reason.map { " (\($0))" } ?? "")"
    }

    static func describe(_ decision: RuleDecision?) -> String {
        guard let decision else { return "no rule matched; the settings decide" }
        var parts = [decision.action.rawValue]
        if let inline = decision.inline { parts.append("inline \(inline)") }
        if let floor = decision.minSeverity { parts.append("from \(floor.rawValue)") }
        if let cap = decision.maxComments { parts.append("at most \(cap)") }
        if decision.attribution == true { parts.append("with attribution") }
        return "\(decision.rule): \(parts.joined(separator: ", "))"
    }
}

typealias RuleEvaluationLog = JSONLinesLog<RuleEvaluation>

extension JSONLinesLog where Record == RuleEvaluation {
    /// `history/rules/YYYY-MM.jsonl`.
    static func rules(in historyDirectory: URL) -> RuleEvaluationLog {
        RuleEvaluationLog(directory: historyDirectory.appendingPathComponent("rules")) { $0.at }
    }
}
