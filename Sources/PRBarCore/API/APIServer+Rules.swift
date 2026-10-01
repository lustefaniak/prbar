import Foundation

/// The Rules tab's requests: the user's rule files, recorded decisions,
/// and evaluating unsaved edits against PRs and against the record.
extension APIServer {
    /// The user's rules with `draft` applied; nil when that leaves no
    /// policies.
    func draftRules(_ draft: RuleDraft) throws -> Rules? {
        let directory = runtime.repoConfigs.rulesURL
        return try RuleDirectory.compile(draft.applied(to: RuleDirectory.read(directory)), root: directory.path)
    }

    func ruleFiles() throws -> RuleFilesResult {
        let directory = runtime.repoConfigs.rulesURL
        return RuleFilesResult(
            directory: directory.path, files: try RuleDirectory.read(directory), issue: runtime.repoConfigs.rulesIssue)
    }

    /// The user's layer only: the draft replaces those rules, and a
    /// repository's rules can't be edited here.
    private func personalRecords() -> [RuleEvaluation] {
        (runtime.queue.ruleLog?.readAll() ?? [])
            .filter { $0.ruleLayer == .personal }
            .sorted { $0.at > $1.at }
    }

    func ruleRecords(limit: Int?) -> [RuleRecordSummary] {
        let records = personalRecords().map(Self.summary)
        guard let limit else { return records }
        return Array(records.prefix(limit))
    }

    func replayRule(id: UUID, draft: RuleDraft?) throws -> RuleReplayResult {
        guard let record = personalRecords().first(where: { $0.id == id }) else {
            throw RPCError(code: RPCError.notFound, message: "no recorded rule decision \(id.uuidString)")
        }
        let current = runtime.repoConfigs.config.compiledRules ?? .empty
        var result = RuleReplayResult(
            record: Self.summary(record), now: RuleReplay.replay(record, rules: current).outcome,
            trace: RuleReplay.trace(record, rules: current))
        if let draft {
            do {
                let rules = try draftRules(draft) ?? .empty
                result.draft = RuleReplay.replay(record, rules: rules).outcome
                result.draftTrace = RuleReplay.trace(record, rules: rules)
            } catch {
                result.draftProblem = error.localizedDescription
            }
        }
        return result
    }

    /// The latest record per PR, commit and stage, replayed against the
    /// rules now and against the draft.
    func ruleImpact(_ params: RuleImpactParams, now: Date = Date()) -> RuleImpact {
        let rules: Rules
        do {
            rules = try draftRules(params.draft) ?? .empty
        } catch {
            return RuleImpact(examined: 0, changes: [], draftProblem: error.localizedDescription)
        }
        let current = runtime.repoConfigs.config.compiledRules ?? .empty
        let since = params.days.map { now.addingTimeInterval(-Double($0) * 86_400) } ?? .distantPast
        var seen: Set<String> = []
        var examined = 0
        var changes: [RuleImpact.Change] = []
        for record in personalRecords() where record.at >= since {
            guard seen.insert("\(record.pr)@\(record.headSha)#\(record.stage.rawValue)").inserted else { continue }
            examined += 1
            let before = RuleReplay.replay(record, rules: current).outcome
            let after = RuleReplay.replay(record, rules: rules).outcome
            if before != after {
                changes.append(RuleImpact.Change(record: Self.summary(record), now: before, draft: after))
            }
        }
        return RuleImpact(examined: examined, changes: changes)
    }

    /// Writes one rule file, then reloads the rules. Refused when the file
    /// changed since the client read it, or when the rules wouldn't
    /// compile with it: the editor never saves rules that can't load.
    func saveRuleFile(_ params: SaveRuleFileParams) throws {
        guard RuleDirectory.isRuleFile(params.path) else {
            throw RPCError(
                code: RPCError.invalidParams,
                message: "\(params.path) isn't a rule file: lists.yaml, or a .yaml file in select/ or decide/")
        }
        let directory = runtime.repoConfigs.rulesURL
        let url = directory.appendingPathComponent(params.path)
        let current = FileManager.default.contents(atPath: url.path).flatMap { String(data: $0, encoding: .utf8) }
        guard current == params.base else {
            throw RPCError(code: RPCError.conflict, message: "\(params.path) changed since it was opened")
        }
        var draft = RuleDraft()
        if let text = params.text { draft.files[params.path] = text } else { draft.removed = [params.path] }
        do {
            _ = try draftRules(draft)
        } catch {
            throw RPCError(code: RPCError.refused, message: "not saved, the rules wouldn't load:\n\(error.localizedDescription)")
        }
        do {
            if let text = params.text {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url, options: .atomic)
            } else {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            throw RPCError(code: RPCError.internalError, message: "\(params.path): \(error.localizedDescription)")
        }
        runtime.repoConfigs.reloadIfChanged()
    }

    nonisolated static func summary(_ record: RuleEvaluation) -> RuleRecordSummary {
        RuleRecordSummary(
            id: record.id, at: record.at, stage: record.stage, layer: record.ruleLayer, pr: record.pr,
            title: record.title, outcome: record.outcome)
    }
}
