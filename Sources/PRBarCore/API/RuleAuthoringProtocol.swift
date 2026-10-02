import Foundation

/// What rules can read and write, from the server's own build: a client of
/// another version would offer names this server's compiler refuses.
struct RuleCatalogParams: Codable, Sendable {
    /// Nil: every stage.
    var stage: String?
}

struct RuleCatalogResult: Codable, Sendable, Equatable {
    struct Fact: Codable, Sendable, Equatable {
        /// `pr.additions`; a list element's fields as `pr.files[].path`.
        var path: String
        var type: String
        var help: String
    }

    struct Output: Codable, Sendable, Equatable {
        /// Nested blocks as `auto_approve.enabled`.
        var name: String
        var type: String
        var required: Bool
        var help: String
        /// Allowed values, with what each does.
        var values: [String: String]?
    }

    struct Stage: Codable, Sendable, Equatable {
        var stage: String
        var facts: [Fact]
        var outputs: [Output]
    }

    struct Function: Codable, Sendable, Equatable {
        var signature: String
        var help: String
    }

    struct Example: Codable, Sendable, Equatable {
        var id: String
        var stage: String
        var title: String
        var detail: String
        /// Relative to the rules directory.
        var path: String
        var text: String
        var lists: [String: [String]]?
    }

    var stages: [Stage]
    var functions: [Function]
    var examples: [Example]
    /// The list names in the user's lists.yaml.
    var lists: [String]
}

/// Compile a draft without evaluating it on anything.
struct CheckRulesParams: Codable, Sendable {
    var draft: RuleDraft
}

struct CheckRulesResult: Codable, Sendable, Equatable {
    /// Nil when the rules compile.
    var problem: String?
    /// Policy files per stage, in evaluation order.
    var select: [String]
    var decide: [String]
    var configure: [String]
    /// List names and how many entries each has.
    var lists: [String: Int]
    /// Things that compile but won't do what they look like.
    var notes: [String]
}

/// A change to the user's rules an agent asked for, waiting for the user.
struct RuleProposal: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var at: Date
    /// The client that proposed it, as it said in `hello`.
    var by: String
    var title: String
    var why: String
    /// The user's layer only.
    var draft: RuleDraft
    /// Each file the draft touches as it was when proposed; absent for a
    /// file the draft creates. Accepting is refused when one moved since.
    var base: [String: String]
    /// What it changes in the recorded decisions, worked out when proposed.
    var impact: RuleImpact?
}

struct ProposeRulesParams: Codable, Sendable {
    var title: String
    var why: String
    var draft: RuleDraft
}

struct ProposeRulesResult: Codable, Sendable, Equatable {
    var proposal: RuleProposal
    /// Saved at once: the user set `agents.rules` to `allow`.
    var applied: Bool
}

struct RuleProposalParams: Codable, Sendable {
    var id: UUID
}

extension RuleImpact {
    /// Changes the record could answer.
    var decided: [Change] { changes.filter { !$0.draft.hasPrefix("undecided") } }
    /// Records the draft needs a lazy fact for that wasn't fetched when
    /// they were made, such as a fact newer than the record.
    var undecided: [Change] { changes.filter { $0.draft.hasPrefix("undecided") } }

    /// "changes 3 of the 40 decisions recorded in the last 30 days".
    func sentence(days: Int?) -> String {
        let span = days.map { " in the last \($0) day\($0 == 1 ? "" : "s")" } ?? ""
        var text = decided.isEmpty
            ? "changes none of the \(examined) decisions recorded\(span)"
            : "changes \(decided.count) of the \(examined) decisions recorded\(span)"
        if !undecided.isEmpty {
            text += "; \(undecided.count) can't tell, recorded before what the draft reads was fetched"
        }
        return text
    }
}

extension RuleDraft {
    /// `writes decide/a.yaml; deletes decide/b.yaml`.
    var summary: String {
        var parts: [String] = []
        if !files.isEmpty { parts.append("writes " + files.keys.sorted().joined(separator: ", ")) }
        if !removed.isEmpty { parts.append("deletes " + removed.sorted().joined(separator: ", ")) }
        return parts.joined(separator: "; ")
    }
}

/// Proposals waiting for the user, kept in the state directory so they
/// survive a restart.
@MainActor
@Observable
final class RuleProposals {
    private(set) var pending: [RuleProposal]
    @ObservationIgnored private let file: JSONStateFile<[RuleProposal]>?

    /// Without a file they live only as long as the process: tests, and
    /// runtimes that write nothing.
    init(file: JSONStateFile<[RuleProposal]>? = nil) {
        self.file = file
        pending = file?.load() ?? []
    }

    func add(_ proposal: RuleProposal) {
        pending.append(proposal)
        file?.save(pending)
    }

    func remove(_ id: UUID) {
        pending.removeAll { $0.id == id }
        file?.save(pending)
    }

    func proposal(_ id: UUID) -> RuleProposal? {
        pending.first { $0.id == id }
    }
}
