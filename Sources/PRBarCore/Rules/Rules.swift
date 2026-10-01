import CEL
import CELExtensions
import CELPolicy
import CELSwift
import Foundation

/// Facts that cost a GitHub call, fetched only when a rule's outcome
/// depends on them: the rules first run with them unknown (CEL partial
/// evaluation), and a result that is still undecided names exactly which
/// ones it needs.
enum LazyFact: String, Sendable, Hashable, CaseIterable, Codable {
    case files
    case committers

    var pattern: UnknownPattern { UnknownPattern("pr").qualified(by: rawValue) }

    func names(_ trail: AttributeTrail) -> Bool {
        let text = trail.description
        let prefix = "pr.\(rawValue)"
        guard text.hasPrefix(prefix) else { return false }
        let rest = text.dropFirst(prefix.count)
        return rest.isEmpty || rest.hasPrefix(".") || rest.hasPrefix("[")
    }
}

/// The lazy facts fetched for one head commit. A fact in `fetched` with a
/// nil value is one whose fetch failed: rules see null, so `has()` is false.
struct LazyFactValues: Sendable, Hashable {
    var files: [FileFacts]?
    var committers: [String]?
    var fetched: Set<LazyFact> = []

    var pending: Set<LazyFact> { Set(LazyFact.allCases).subtracting(fetched) }

    mutating func merge(_ other: LazyFactValues) {
        if other.fetched.contains(.files) { files = other.files }
        if other.fetched.contains(.committers) { committers = other.committers }
        fetched.formUnion(other.fetched)
    }
}

/// Who wrote a set of rules, in evaluation order: the repository's first,
/// then the user's, each seeing the answer of the layers under it as
/// `below`; the highest layer that matches decides.
enum RuleLayer: String, Codable, Sendable, Hashable, CaseIterable {
    case repo
    case personal
}

extension ResolvedRepoConfig {
    /// The rule layers that apply, bottom up.
    var ruleLayers: [(layer: RuleLayer, rules: Rules)] {
        var layers: [(RuleLayer, Rules)] = []
        if trustRepoRules, let repoRules { layers.append((.repo, repoRules)) }
        if let rules { layers.append((.personal, rules)) }
        return layers
    }
}

/// Where the lazy facts that aren't in the diff come from: GitHub through
/// `gh` in production. The files come from the diff the worker fetches.
struct LazyFactFetcher: Sendable {
    var committers: @Sendable (_ owner: String, _ repo: String, _ number: Int) async throws -> [String]
}

extension LazyFactFetcher {
    init(_ client: GHClient) {
        self.init(committers: { try await client.fetchCommitters(owner: $0, repo: $1, number: $2) })
    }
}

/// A stage's answer: decided (a rule's output, or nil when none matched),
/// or waiting for lazy facts.
enum RuleOutcome<Output: Sendable>: Sendable {
    case decided(Output?)
    case needs(Set<LazyFact>)
}

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
    /// Tells versions of the rules apart, in history records.
    let digest: String
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
            .library(.strings), .library(.lists), .library(.sets), .library(.math),
            .function(
                "glob",
                .overload("glob_string_string") { (value: String, pattern: String) in
                    GlobMatcher.match(pattern, value)
                },
                // Any of the patterns, later ones winning and `!` excluding,
                // as `repoGlobs` reads them: glob(pr.repo, lists.team_repos).
                .overload("glob_string_list") { (value: String, patterns: [String]) in
                    GlobMatcher.anyMatch(patterns, value)
                }),
            // Whether any changed file matches. Taking the list rather than
            // `pr` keeps a rule waiting on the files alone, not on every
            // lazy fact of the PR. The list arrives as a plain value since
            // it is null when the fetch failed, which matches nothing.
            .function("touches", fileListOverload("touches_files_string") { files, pattern in
                files.contains { GlobMatcher.match(pattern, $0.path) }
            }),
            // Whether every changed file matches; false with no files, so
            // "only docs changed" never holds for a change it knows nothing of.
            .function("only", fileListOverload("only_files_string") { files, pattern in
                !files.isEmpty && files.allSatisfy { GlobMatcher.match(pattern, $0.path) }
            })
        )
    }

    /// `(files, glob) -> bool`, with `files` taken as dyn: it is null when
    /// fetching it failed, which answers false.
    private static func fileListOverload(
        _ id: String, _ test: @escaping @Sendable ([FileFacts], String) -> Bool
    ) -> FunctionDecl.Option {
        .overload(id, argumentTypes: [.dyn, .string], resultType: .bool, .binaryBinding { files, pattern in
            guard case .string(let glob) = pattern else { return .error(EvalError("the pattern must be a string")) }
            if case .null = files { return .bool(false) }
            do {
                return .bool(test(try files.decoded(as: [FileFacts].self, options: coding), glob))
            } catch {
                return .error(EvalError("not a list of files: \(error)"))
            }
        })
    }

    /// - Throws: `ValidationError` with every problem, positioned in its file.
    static func compile(select: [Source], decide: [Source], lists: [String: [String]] = [:]) throws -> Rules {
        let env = try environment()
        func load<F, O>(_ source: Source, _ fields: [RuleOutputs.Field]) throws -> TypedProgram<F, O?> {
            let text = try RuleOutputs.expand(source.text, path: source.path, fields: fields)
            return try TypedProgram<F, O?>(
                policy: PolicySource(text, description: source.path), environment: env,
                options: coding, programOptions: programOptions)
        }
        return Rules(
            select: try select.map { try load($0, RuleOutputs.select) },
            decide: try decide.map { try load($0, RuleOutputs.decide) }, lists: lists,
            sources: select + decide, digest: digest(select + decide, lists: lists), failure: nil)
    }

    static func unloaded(_ reason: String) -> Rules {
        Rules(select: [], decide: [], lists: [:], sources: [], digest: "unloaded", failure: reason)
    }

    static let unloadedRuleID = "rules-not-loaded"
    /// The id a decision carries when evaluating the rules failed.
    static let errorRuleID = "rule-error"

    /// Nil when no select policy matches. Every fact must be known.
    func select(_ facts: SelectFacts) throws -> RuleSelection? {
        guard case .decided(let selection) = try select(facts, pending: []) else { return nil }
        return selection
    }

    /// `pending`: the lazy facts not fetched yet, unknown to the rules.
    func select(_ facts: SelectFacts, pending: Set<LazyFact>) throws -> RuleOutcome<RuleSelection> {
        try Self.first(select, facts, pending: pending)
    }

    /// Nil when no decide policy matches. Every fact must be known.
    func decide(_ facts: DecideFacts) throws -> RuleDecision? {
        guard case .decided(let decision) = try decide(facts, pending: []) else { return nil }
        return decision
    }

    func decide(_ facts: DecideFacts, pending: Set<LazyFact>) throws -> RuleOutcome<RuleDecision> {
        if failure != nil { return .decided(RuleDecision(rule: Self.unloadedRuleID, action: .none)) }
        return try Self.first(decide, facts, pending: pending)
    }

    /// The first policy that matches, in order. A policy whose result
    /// depends on a pending fact stops the search: a later one can't decide
    /// before an earlier one has.
    private static func first<F, O>(
        _ programs: [TypedProgram<F, O?>], _ facts: F, pending: Set<LazyFact>
    ) throws -> RuleOutcome<O> {
        let unknowns = pending.sorted { $0.rawValue < $1.rawValue }.map(\.pattern)
        for program in programs {
            switch try program.evaluate(facts, unknowns: unknowns) {
            case .value(let output?):
                return .decided(output)
            case .value(nil):
                continue
            case .unknown(let missing):
                let needed = pending.filter { fact in missing.contains(where: fact.names) }
                return .needs(needed.isEmpty ? pending : needed)
            }
        }
        return .decided(nil)
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

    private static func describeOutput(_ output: Any) -> String {
        switch output {
        case let selection as RuleSelection: return describe(selection)
        case let decision as RuleDecision: return describe(decision)
        default: return String(describing: output)
        }
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
                text += (text.isEmpty ? "" : "\n") + "matched: \(describeOutput(output))"
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
