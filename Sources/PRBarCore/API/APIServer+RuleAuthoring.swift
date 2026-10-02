import Foundation
import Yams

/// Writing rules from outside the Rules tab: what a rule can use, checking
/// a draft, a repository's rules tried before they are merged, and changes
/// coding agents propose for the user to accept.
extension APIServer {
    /// A repository's `.prbar/rules` from a draft: the files are the whole
    /// directory, not edits to one.
    nonisolated static func repoRules(_ draft: RuleDraft) throws -> Rules {
        let root = "\(draft.repository ?? "repository")/.prbar/rules"
        return try RuleDirectory.compile(draft.files, root: root) ?? .empty
    }

    /// The draft compiled as the layer it is for.
    func compile(_ draft: RuleDraft) throws -> Rules {
        draft.isRepository ? try Self.repoRules(draft) : try draftRules(draft) ?? .empty
    }

    /// `config` with the draft in its layer. A repository draft is used
    /// whether or not the user trusts that repository's rules: trying them
    /// is the point.
    nonisolated static func applying(_ draft: RuleDraft, compiled: Rules, to config: ResolvedRepoConfig) -> ResolvedRepoConfig {
        guard draft.isRepository else { return config.with(rules: compiled) }
        var rule = config.rule
        rule.trustRepoRules = true
        return ResolvedRepoConfig(rule: rule, defaults: config.defaults, rules: config.rules, repoRules: compiled)
    }

    func ruleCatalog(stage: String?) throws -> RuleCatalogResult {
        var stages = RuleCatalog.Stage.allCases
        if let stage {
            guard let one = RuleCatalog.Stage(rawValue: stage) else {
                throw RPCError(code: RPCError.invalidParams, message: "no stage \(stage): configure, select or decide")
            }
            stages = [one]
        }
        let text = ((try? RuleDirectory.read(runtime.repoConfigs.rulesURL)) ?? [:])["lists.yaml"] ?? ""
        let lists = ((try? YAMLDecoder().decode([String: [String]]?.self, from: text)) ?? nil)?.keys.sorted() ?? []
        return RuleCatalogResult(
            stages: stages.map { stage in
                RuleCatalogResult.Stage(
                    stage: stage.rawValue,
                    facts: RuleCatalog.facts(stage).map { .init(path: $0.path, type: $0.type, help: $0.help) },
                    outputs: Self.outputs(Self.fields(stage), prefix: ""))
            },
            functions: RuleCatalog.functions.map { .init(signature: $0.signature, help: $0.help) }
                + RuleCatalog.constants.map { .init(signature: $0, help: "A severity, compared by rank: info < suggestion < warning < blocker.") },
            examples: RuleExamples.all().filter { stages.contains($0.stage) }.map {
                .init(id: $0.id, stage: $0.stage.rawValue, title: $0.title, detail: $0.detail, path: $0.path, text: $0.text,
                      lists: $0.lists.isEmpty ? nil : $0.lists)
            },
            lists: lists)
    }

    nonisolated static func fields(_ stage: RuleCatalog.Stage) -> [RuleOutputs.Field] {
        switch stage {
        case .configure: return RuleOutputs.configure
        case .select: return RuleOutputs.select
        case .decide: return RuleOutputs.decide
        }
    }

    nonisolated static func outputs(_ fields: [RuleOutputs.Field], prefix: String) -> [RuleCatalogResult.Output] {
        fields.flatMap { field -> [RuleCatalogResult.Output] in
            let name = prefix + field.name
            let type: String
            var values: [String: String]? = field.values.isEmpty ? nil : field.values
            switch field.kind {
            case .string: type = "string"
            case .bool: type = "bool"
            case .int: type = "int"
            case .number: type = "number"
            case .oneOf(let allowed):
                type = "one of"
                values = Dictionary(uniqueKeysWithValues: allowed.map { ($0, field.values[$0] ?? "") })
            case .severity:
                type = "severity"
                values = Dictionary(uniqueKeysWithValues: AnnotationSeverity.allCases.map { ($0.rawValue, "") })
            case .strings: type = "list of strings"
            case .stringMap: type = "map of strings"
            case .object(let inner):
                return [RuleCatalogResult.Output(name: name, type: "block", required: field.required, help: field.help)]
                    + outputs(inner, prefix: name + ".")
            }
            return [RuleCatalogResult.Output(name: name, type: type, required: field.required, help: field.help, values: values)]
        }
    }

    func checkRules(_ draft: RuleDraft) -> CheckRulesResult {
        let files = draft.isRepository ? draft.files : draft.applied(to: (try? RuleDirectory.read(runtime.repoConfigs.rulesURL)) ?? [:])
        func stage(_ name: String) -> [String] {
            files.keys.filter { RuleDirectory.isRuleFile($0) && $0.hasPrefix("\(name)/") }.sorted()
        }
        var result = CheckRulesResult(
            problem: nil, select: stage("select"), decide: stage("decide"), configure: stage("configure"), lists: [:], notes: [])
        do {
            let rules = try compile(draft)
            result.lists = rules.lists.mapValues(\.count)
        } catch {
            result.problem = error.localizedDescription
        }
        let ignored = files.keys.filter { !RuleDirectory.isRuleFile($0) }.sorted()
        if !ignored.isEmpty {
            result.notes.append("Not read: \(ignored.joined(separator: ", ")). Rules are lists.yaml and .yaml files in select/, decide/ and configure/.")
        }
        if draft.isRepository, !result.configure.isEmpty {
            result.notes.append("A repository's configure rules are compiled but never applied: per-repository settings stay with each user.")
        }
        return result
    }

    /// A change to the user's rules, kept for the user to accept; saved at
    /// once only for an agent under `agents.rules: allow`. Never a
    /// repository's rules: those change through a pull request.
    func proposeRules(_ params: ProposeRulesParams, by client: String, agent: Bool) throws -> ProposeRulesResult {
        guard !params.draft.isRepository else {
            throw RPCError(
                code: RPCError.invalidParams,
                message: "a repository's rules change through a pull request to its .prbar/rules, not a proposal")
        }
        guard !params.draft.files.isEmpty || !params.draft.removed.isEmpty else {
            throw RPCError(code: RPCError.invalidParams, message: "the draft changes nothing")
        }
        for path in params.draft.files.keys.sorted() + params.draft.removed where !RuleDirectory.isRuleFile(path) {
            throw RPCError(
                code: RPCError.invalidParams,
                message: "\(path) isn't a rule file: lists.yaml, or a .yaml file in select/, decide/ or configure/")
        }
        do {
            _ = try draftRules(params.draft)
        } catch {
            throw RPCError(code: RPCError.refused, message: "not proposed, the rules wouldn't load:\n\(error.localizedDescription)")
        }
        let directory = runtime.repoConfigs.rulesURL
        var base: [String: String] = [:]
        for path in Array(params.draft.files.keys) + params.draft.removed {
            if let text = Self.read(directory.appendingPathComponent(path)) { base[path] = text }
        }
        let proposal = RuleProposal(
            id: UUID(), at: Date(), by: client, title: params.title, why: params.why, draft: params.draft, base: base,
            impact: ruleImpact(RuleImpactParams(draft: params.draft, days: 30)))
        // Only an agent the user allowed saves directly. The CLI's propose
        // waits too: an agent with a shell would otherwise reach it to skip
        // the user's approval.
        if agent, runtime.repoConfigs.config.agents.rules == .allow {
            try write(proposal)
            return ProposeRulesResult(proposal: proposal, applied: true)
        }
        runtime.repoConfigs.proposals.add(proposal)
        return ProposeRulesResult(proposal: proposal, applied: false)
    }

    func acceptRuleProposal(_ id: UUID) throws {
        guard let proposal = runtime.repoConfigs.proposals.proposal(id) else {
            throw RPCError(code: RPCError.notFound, message: "no rule proposal \(id.uuidString)")
        }
        try write(proposal)
        runtime.repoConfigs.proposals.remove(id)
    }

    /// Writes every file of a proposal, or none: refused when a file moved
    /// since it was proposed, or when the rules wouldn't compile now.
    private func write(_ proposal: RuleProposal) throws {
        let directory = runtime.repoConfigs.rulesURL
        let paths = Array(proposal.draft.files.keys) + proposal.draft.removed
        for path in paths.sorted() where Self.read(directory.appendingPathComponent(path)) != proposal.base[path] {
            throw RPCError(code: RPCError.conflict, message: "\(path) changed since this was proposed; ask for a new proposal")
        }
        do {
            _ = try draftRules(proposal.draft)
        } catch {
            throw RPCError(code: RPCError.refused, message: "not saved, the rules wouldn't load:\n\(error.localizedDescription)")
        }
        do {
            for (path, text) in proposal.draft.files {
                let url = directory.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url, options: .atomic)
            }
            for path in proposal.draft.removed {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(path))
            }
        } catch {
            throw RPCError(code: RPCError.internalError, message: error.localizedDescription)
        }
        runtime.repoConfigs.reloadIfChanged()
    }

    nonisolated static func read(_ url: URL) -> String? {
        FileManager.default.contents(atPath: url.path).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// What a repository's draft rules would have answered on the recorded
    /// decisions about that repository. A record of the repository's own
    /// layer is used where there is one, since its `below` is the settings'
    /// answer; otherwise the user's, whose `below` was the settings' too
    /// when no repository rules were trusted.
    func repoRuleImpact(_ params: RuleImpactParams, now: Date = Date()) -> RuleImpact {
        guard let repository = params.draft.repository else {
            return RuleImpact(examined: 0, changes: [], draftProblem: "say which repository the rules are for")
        }
        let rules: Rules
        do {
            rules = try Self.repoRules(params.draft)
        } catch {
            return RuleImpact(examined: 0, changes: [], draftProblem: error.localizedDescription)
        }
        let since = params.days.map { now.addingTimeInterval(-Double($0) * 86_400) } ?? .distantPast
        let records = (runtime.queue.ruleLog?.readAll() ?? [])
            .filter { $0.repo.caseInsensitiveCompare(repository) == .orderedSame && $0.at >= since }
            .sorted { $0.at > $1.at }
        var chosen: [String: RuleEvaluation] = [:]
        var order: [String] = []
        for record in records {
            let key = "\(record.pr)@\(record.headSha)#\(record.stage.rawValue)"
            if let kept = chosen[key] {
                if kept.ruleLayer != .repo, record.ruleLayer == .repo { chosen[key] = record }
                continue
            }
            chosen[key] = record
            order.append(key)
        }
        var changes: [RuleImpact.Change] = []
        for key in order {
            guard let record = chosen[key] else { continue }
            let before = record.ruleLayer == .repo ? record.outcome : Rules.describe(nil as RuleDecision?)
            let after = RuleReplay.replay(record, rules: rules).outcome
            if before != after {
                changes.append(RuleImpact.Change(record: Self.summary(record), now: before, draft: after))
            }
        }
        return RuleImpact(examined: order.count, changes: changes)
    }
}
