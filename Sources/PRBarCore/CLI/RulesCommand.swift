import Foundation

/// `prbar-review rules check | explain <pr>`: the rules directory from the
/// outside. `check` compiles it here, without a server, so an edit can be
/// tried before PRBar picks it up; `explain` asks the server, which holds
/// the PR and its review, why the rules decide what they do.
///
/// Exit status: 0 fine, 1 the rules don't compile, 2 bad arguments,
/// 3 no reachable server.
enum RulesCommand: Equatable {
    /// Without a draft, compiled here; with one, by the server.
    case check(configPath: String?, draft: RuleDraftSource? = nil)
    case explain(PRReference, configPath: String?, draft: RuleDraftSource? = nil)
    /// Facts, outputs, functions and examples, from the server's build.
    case catalog(stage: String?, example: String?, configPath: String?)
    /// What a draft changes in the recorded decisions.
    case impact(RuleDraftSource, days: Int?, full: Bool, configPath: String?)
    case propose(RuleDraftSource, title: String, why: String, configPath: String?)
    case proposals(configPath: String?)
    case accept(id: String, configPath: String?)
    case reject(id: String, configPath: String?)
    case history(Filter, limit: Int, json: Bool)
    /// One recorded evaluation (by id prefix), or every one the filter keeps.
    case replay(id: String?, Filter, watch: Bool, configPath: String?, repoRules: String?)
    /// The JSON schema of a rules file, for editors.
    case schema(RuleSchema.File)
    /// prbar.yaml's old `repos:` into a configure rule.
    case convert(configPath: String?, dryRun: Bool)

    struct Filter: Equatable {
        /// `owner/repo#number`, or a checkout's root for local reviews.
        var pr: String?
        var days: Int = 7
    }

    init?(args: [String]) {
        guard args.first == "rules", args.count >= 2 else { return nil }
        var configPath: String?
        var positional: [String] = []
        var filter = Filter()
        var limit = 20
        var json = false
        var watch = false
        var repoRules: String?
        var dryRun = false
        var draft = RuleDraftSource()
        var days: Int?
        var full = false
        var example: String?
        var title: String?
        var why: String?
        var i = 2
        func value() -> String? {
            i += 1
            return i < args.count ? args[i] : nil
        }
        while i < args.count {
            switch args[i] {
            case "--config":
                guard let v = value() else { return nil }
                configPath = v
            case "--pr":
                guard let v = value() else { return nil }
                if let target = Invocation.parseTarget(v) {
                    filter.pr = "\(target.owner)/\(target.repo)#\(target.number)"
                } else {
                    filter.pr = v
                }
            case "--days":
                guard let v = value(), let n = Int(v), n > 0 else { return nil }
                filter.days = n
                days = n
            case "--draft":
                guard let v = value() else { return nil }
                draft.dir = v
            case "--remove":
                guard let v = value() else { return nil }
                draft.remove.append(v)
            case "--repo":
                guard let v = value(), v.split(separator: "/").count == 2 else { return nil }
                draft.repository = v
            case "--full":
                full = true
            case "--example":
                guard let v = value() else { return nil }
                example = v
            case "--title":
                guard let v = value() else { return nil }
                title = v
            case "--why":
                guard let v = value() else { return nil }
                why = v
            case "--limit":
                guard let v = value(), let n = Int(v), n > 0 else { return nil }
                limit = n
            case "--json":
                json = true
            case "--watch":
                watch = true
            case "--dry-run":
                dryRun = true
            case "--repo-rules":
                guard let v = value() else { return nil }
                repoRules = (v as NSString).expandingTildeInPath
                draft.repoRules = repoRules
            case let flag where flag.hasPrefix("-"):
                return nil
            default:
                positional.append(args[i])
            }
            i += 1
        }
        let drafted = draft.isEmpty ? nil : draft
        switch args[1] {
        case "check" where positional.isEmpty:
            self = .check(configPath: configPath, draft: drafted)
        case "explain" where positional.count == 1:
            guard let target = Invocation.parseTarget(positional[0]) else { return nil }
            self = .explain(PRReference(owner: target.owner, repo: target.repo, number: target.number), configPath: configPath, draft: drafted)
        case "catalog" where positional.count <= 1:
            self = .catalog(stage: positional.first, example: example, configPath: configPath)
        case "impact" where positional.isEmpty:
            guard let drafted else { return nil }
            self = .impact(drafted, days: days ?? 30, full: full, configPath: configPath)
        case "propose" where positional.isEmpty:
            guard let drafted, drafted.repoRules == nil, let title else { return nil }
            self = .propose(drafted, title: title, why: why ?? "", configPath: configPath)
        case "proposals" where positional.isEmpty:
            self = .proposals(configPath: configPath)
        case "accept" where positional.count == 1:
            self = .accept(id: positional[0], configPath: configPath)
        case "reject" where positional.count == 1:
            self = .reject(id: positional[0], configPath: configPath)
        case "schema" where positional.count == 1:
            guard let file = RuleSchema.File(rawValue: positional[0]) else { return nil }
            self = .schema(file)
        case "convert" where positional.isEmpty:
            self = .convert(configPath: configPath, dryRun: dryRun)
        case "history" where positional.isEmpty:
            self = .history(filter, limit: limit, json: json)
        case "replay" where positional.count <= 1:
            self = .replay(id: positional.first, filter, watch: watch, configPath: configPath, repoRules: repoRules)
        default:
            return nil
        }
    }

    static let usage = """
    usage: prbar-review rules check [<draft>] [--config <path>]
           prbar-review rules explain <pr-url|owner/repo#number> [<draft>] [--config <path>]
           prbar-review rules catalog [select|decide|configure] [--example <id>]
           prbar-review rules impact <draft> [--days <n>] [--full]
           prbar-review rules propose --draft <dir> [--remove <path>]... --title <text> [--why <text>]
           prbar-review rules proposals
           prbar-review rules accept|reject <id>
           prbar-review rules history [--pr <pr>] [--days <n>] [--limit <n>] [--json]
           prbar-review rules replay [<id>] [--pr <pr>] [--days <n>] [--watch] [--config <path>]
                                     [--repo-rules <checkout>/.prbar/rules]
           prbar-review rules schema select|decide|configure|lists
           prbar-review rules convert [--config <path>] [--dry-run]

    The rules live in `rules/` beside prbar.yaml (or $PRBAR_RULES):

      rules/lists.yaml        named lists, e.g. `trusted: [alice, bob]`
      rules/select/*.yaml     whether to review a PR at all
      rules/decide/*.yaml     what to post once it is reviewed
      rules/configure/*.yaml  how a repository's PRs are reviewed

    Each file is a CEL policy in cel-go's format. Files run in name order;
    the first one that matches decides, and when none does the repo settings
    in prbar.yaml decide as before.

    A <draft> is rules not saved yet: --draft <dir> lays the rule files in
    <dir> (decide/50-x.yaml, lists.yaml) over yours, --remove <path> drops
    one of yours; or --repo-rules <checkout> is a repository's .prbar/rules
    as it would be merged (--repo owner/name when its origin can't tell).

      check     compile the rules here and list them, or say what's wrong;
                with a draft, the running PRBar compiles it
      explain   ask the running PRBar why it reviews a PR or not, and what
                it posts for the review it holds: every condition, with the
                facts it read; with a draft, what the draft would do
      catalog   every fact, output field, function and example a rule can
                use, from the running PRBar
      impact    replay the decisions recorded in the last --days (30) with
                the draft, listing the ones it changes
      propose   hand a draft of your rules to PRBar for you to accept in
                Settings → Rules; what a coding agent does through MCP
      proposals the proposals waiting; accept or reject one by id
      history   the rule evaluations PRBar recorded, newest first: each
                keeps the exact facts the rules saw
      replay    run the rules as they are now on recorded facts. With an id
                (a prefix from `history` is enough): every condition, and
                whether the answer changed since. Without one: every
                evaluation in the last --days (7), listing the answers your
                edits would change. --watch replays again on every save.
                Decisions a repository's own rules made replay only with
                --repo-rules, against those rules in a local checkout
      schema    the JSON schema of a rules file, which editors use to
                complete and check it; also published at
                \(RuleSchema.baseURL)<file>.schema.json
      convert   turn the `repos:` entries of an older prbar.yaml into
                rules/configure/50-repos.yaml and the `repositories:` lists,
                after checking every repository PRBar has seen resolves to
                the same settings. The old file is kept as
                prbar.yaml.before-rules. --dry-run prints the rule only

    """

    @MainActor
    func run(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        connect: (() async throws -> ServerConnection.Connected)? = nil,
        print: (String) -> Void = { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
        fail: (String) -> Void = { FileHandle.standardError.write(Data("prbar-review: \($0)\n".utf8)) }
    ) async -> Int32 {
        /// Runs `body` against the server, starting one when none answers.
        func withServer(_ configPath: String?, _ body: (APIClient) async throws -> Int32) async -> Int32 {
            let connected: ServerConnection.Connected
            do {
                if let connect {
                    connected = try await connect()
                } else {
                    let configFile = try? CLIConfig.locate(path: configPath, environment: environment)
                    connected = try await ClientReview.launcher(configFile: configFile)()
                }
            } catch {
                fail("cannot reach the PRBar server: \(error.localizedDescription)")
                return 3
            }
            defer { connected.client.close() }
            do {
                return try await body(connected.client)
            } catch {
                fail(error.localizedDescription)
                return 1
            }
        }
        /// A proposal by the start of its id.
        func proposal(_ prefix: String, _ client: APIClient) async throws -> RuleProposal {
            let all = try await client.call(.ruleProposals, as: [RuleProposal].self)
            let matches = all.filter { $0.id.uuidString.lowercased().hasPrefix(prefix.lowercased()) }
            guard matches.count == 1, let match = matches.first else {
                throw RPCError(
                    code: RPCError.notFound,
                    message: matches.isEmpty ? "no rule proposal \(prefix); see `prbar-review rules proposals`" : "\(prefix) matches \(matches.count) proposals; give more of the id")
            }
            return match
        }

        switch self {
        case let .check(configPath, draft?):
            return await withServer(configPath) { client in
                let loaded = try await draft.load()
                let result = try await client.call(.checkRules, CheckRulesParams(draft: loaded), as: CheckRulesResult.self)
                print(RulesText.check(result, draft: loaded))
                return result.problem == nil ? 0 : 1
            }

        case let .catalog(stage, example, configPath):
            return await withServer(configPath) { client in
                let catalog = try await client.call(.ruleCatalog, RuleCatalogParams(stage: stage), as: RuleCatalogResult.self)
                print(RulesText.catalog(catalog, example: example))
                return 0
            }

        case let .impact(source, days, full, configPath):
            return await withServer(configPath) { client in
                let draft = try await source.load()
                let impact = try await client.call(.ruleImpact, RuleImpactParams(draft: draft, days: days), as: RuleImpact.self)
                print(RulesText.impact(impact, draft: draft, days: days, full: full))
                return impact.draftProblem == nil ? 0 : 1
            }

        case let .propose(source, title, why, configPath):
            return await withServer(configPath) { client in
                let draft = try await source.load()
                let result = try await client.call(
                    .proposeRules, ProposeRulesParams(title: title, why: why, draft: draft), as: ProposeRulesResult.self)
                print(RulesText.proposed(result))
                return 0
            }

        case .proposals(let configPath):
            return await withServer(configPath) { client in
                print(RulesText.proposals(try await client.call(.ruleProposals, as: [RuleProposal].self)))
                return 0
            }

        case let .accept(id, configPath):
            return await withServer(configPath) { client in
                let found = try await proposal(id, client)
                _ = try await client.call(.acceptRuleProposal, RuleProposalParams(id: found.id), as: APIEmpty.self)
                print("Accepted \(RulesText.short(found.id)) \"\(found.title)\": \(RulesText.files(found.draft)).")
                return 0
            }

        case let .reject(id, configPath):
            return await withServer(configPath) { client in
                let found = try await proposal(id, client)
                _ = try await client.call(.rejectRuleProposal, RuleProposalParams(id: found.id), as: APIEmpty.self)
                print("Rejected \(RulesText.short(found.id)) \"\(found.title)\"; nothing was saved.")
                return 0
            }

        case .check(let configPath, nil):
            let configFile: URL
            do {
                configFile = try CLIConfig.locate(path: configPath, environment: environment)
                    ?? ConfigLocation.userConfigURL(environment: environment)
            } catch {
                fail(error.localizedDescription)
                return 2
            }
            let directory = RuleDirectory.url(configFile: configFile, environment: environment)
            do {
                guard let rules = try RuleDirectory.load(directory) else {
                    print("No rules in \(directory.path); the repo settings in prbar.yaml decide.")
                    return 0
                }
                print(Self.describe(rules, in: directory))
                return 0
            } catch {
                fail(error.localizedDescription)
                return 1
            }

        case .schema(let file):
            print(String(RuleSchema.json(file).dropLast()))
            return 0

        case let .convert(configPath, dryRun):
            do {
                let configURL = try CLIConfig.locate(path: configPath, environment: environment)
                    ?? ConfigLocation.userConfigURL(environment: environment)
                let rulesURL = RuleDirectory.url(configFile: configURL, environment: environment)
                let written = try RulesConvert.run(
                    configURL: configURL, rulesURL: rulesURL,
                    repositories: RulesConvert.knownRepositories(
                        stateDirectory: ConfigLocation.stateDirectory(environment: environment)),
                    dryRun: dryRun)
                if dryRun {
                    print(written.ruleText)
                    print("# checked \(written.checked.count) repositories: \(written.checked.joined(separator: ", "))")
                } else {
                    print("Converted \(written.entries) repos: entries into \(written.rulePath).")
                    print("Checked \(written.checked.count) repositories; each resolves to the same settings as before.")
                    print("The old config is kept as \(written.backupPath).")
                }
                return 0
            } catch {
                fail(error.localizedDescription)
                return 1
            }

        case let .history(filter, limit, json):
            let records = Array(Self.evaluations(filter, environment: environment).prefix(limit))
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                encoder.dateEncodingStrategy = .iso8601
                for record in records {
                    print((try? encoder.encode(record)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
                }
            } else if records.isEmpty {
                print("No rule evaluations recorded in the last \(filter.days) days\(filter.pr.map { " for \($0)" } ?? ""). PRBar records one each time a rule decides, or none matches, for a PR.")
            } else {
                records.map(Self.line).forEach(print)
            }
            return 0

        case let .replay(id, filter, watch, configPath, repoRulesPath):
            let directory: URL
            do {
                directory = try Self.rulesDirectory(configPath: configPath, environment: environment)
            } catch {
                fail(error.localizedDescription)
                return 2
            }
            var target: RuleEvaluation?
            if let id {
                let all = Self.evaluations(Filter(pr: filter.pr, days: 365), environment: environment)
                let matches = all.filter { $0.id.uuidString.lowercased().hasPrefix(id.lowercased()) }
                guard matches.count == 1, let match = matches.first else {
                    fail(matches.isEmpty ? "no recorded evaluation \(id); see `prbar-review rules history`" : "\(id) matches \(matches.count) evaluations; give more of the id")
                    return 2
                }
                target = match
            }
            var seen: [String: Data]?
            var code: Int32 = 0
            repeat {
                let fingerprint = RuleDirectory.fingerprint(directory).merging(
                    repoRulesPath.map { RuleDirectory.fingerprint(URL(fileURLWithPath: $0)) } ?? [:]
                ) { mine, _ in mine }
                if fingerprint != seen {
                    if seen != nil { print("\n--- \(Self.timestamp(Date())): the rules changed\n") }
                    seen = fingerprint
                    do {
                        let personal = try RuleDirectory.load(directory)
                        let repo = try repoRulesPath.map { try RuleDirectory.load(URL(fileURLWithPath: $0)) }
                        func rules(for evaluation: RuleEvaluation) -> Rules?? {
                            switch evaluation.ruleLayer {
                            case .personal: return .some(personal)
                            case .repo: return repo
                            }
                        }
                        if let target {
                            guard let rules = rules(for: target) else {
                                fail("\(target.pr)'s own rules made this decision; replay it with --repo-rules <checkout>/.prbar/rules")
                                return 2
                            }
                            print(Self.describe(RuleReplay.replay(target, rules: rules), rules: rules, explain: true))
                        } else {
                            var skipped = 0
                            var results: [RuleReplay.Result] = []
                            for evaluation in Self.evaluations(filter, environment: environment) {
                                guard let rules = rules(for: evaluation) else {
                                    skipped += 1
                                    continue
                                }
                                results.append(RuleReplay.replay(evaluation, rules: rules))
                            }
                            print(Self.summary(results, days: filter.days, directory: directory, skippedRepo: skipped))
                        }
                        code = 0
                    } catch {
                        fail(error.localizedDescription)
                        code = 1
                    }
                }
                if watch { try? await Task.sleep(for: .seconds(1)) }
            } while watch && !Task.isCancelled
            return code

        case let .explain(ref, configPath, source):
            return await withServer(configPath) { client in
                let draft = try await source?.load()
                let explanation = try await client.call(
                    .explainRules, ExplainRulesParams(pr: ref, draft: draft), as: RulesExplanation.self)
                print(RulesText.explanation(explanation, draft: draft))
                return explanation.draftProblem == nil ? 0 : 1
            }
        }
    }

    static func rulesDirectory(configPath: String?, environment: [String: String]) throws -> URL {
        let configFile = try CLIConfig.locate(path: configPath, environment: environment)
            ?? ConfigLocation.userConfigURL(environment: environment)
        return RuleDirectory.url(configFile: configFile, environment: environment)
    }

    static func evaluations(_ filter: Filter, environment: [String: String], now: Date = Date()) -> [RuleEvaluation] {
        let since = now.addingTimeInterval(-Double(filter.days) * 86_400)
        return RuleEvaluationLog.rules(in: HistoryLocation.directory(environment: environment))
            .read(since: since)
            .filter { $0.at >= since && (filter.pr == nil || $0.pr == filter.pr) }
            .sorted { $0.at > $1.at }
    }

    static func line(_ evaluation: RuleEvaluation) -> String {
        let layer = evaluation.ruleLayer == .repo ? "  [repo's rules]" : ""
        return "\(evaluation.id.uuidString.prefix(8).lowercased())  \(timestamp(evaluation.at))  \(evaluation.stage.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0))  \(evaluation.pr)  \(evaluation.outcome)\(layer)"
    }

    static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    static func describe(_ result: RuleReplay.Result, rules: Rules?, explain: Bool) -> String {
        let e = result.evaluation
        let digestNow = rules?.digest ?? "none"
        var lines = [
            "\(e.stage.rawValue) of \(e.pr) \(e.title) (head \(e.headSha.prefix(7))), recorded \(timestamp(e.at))",
            "",
            "recorded: \(e.outcome)   [rules \(e.rulesDigest)]",
            "now:      \(result.outcome)   [rules \(digestNow)]\(result.changed ? "   CHANGED" : "")",
        ]
        if explain {
            lines += ["", RuleReplay.explain(e, rules: rules)]
        }
        return lines.joined(separator: "\n")
    }

    static func summary(_ results: [RuleReplay.Result], days: Int, directory: URL, skippedRepo: Int = 0) -> String {
        let changed = results.filter(\.changed)
        var lines = [
            "Replayed \(results.count) evaluation\(results.count == 1 ? "" : "s") from the last \(days) day\(days == 1 ? "" : "s") with the rules in \(directory.path): \(changed.isEmpty ? "no answer changes." : "\(changed.count) would change.")",
        ]
        if skippedRepo > 0 {
            lines.append("\(skippedRepo) more were made by a repository's own rules; replay them with --repo-rules <checkout>/.prbar/rules.")
        }
        for result in changed {
            lines.append("")
            lines.append(line(result.evaluation))
            lines.append("    now: \(result.outcome)")
        }
        if !changed.isEmpty {
            lines.append("")
            lines.append("Next: prbar-review rules replay <id> shows every condition of one of them.")
        }
        return lines.joined(separator: "\n")
    }

    static func describe(_ rules: Rules, in directory: URL) -> String {
        func names(_ stage: String) -> String {
            let files = RuleDirectory.files(stage, in: directory).map(\.lastPathComponent)
            return files.isEmpty ? "none" : files.joined(separator: ", ")
        }
        var lines = [
            "Rules in \(directory.path) compile.",
            "select: \(names("select"))",
            "decide: \(names("decide"))",
        ]
        if !rules.lists.isEmpty {
            lines.append("lists:  " + rules.lists.keys.sorted().map { "\($0) (\(rules.lists[$0]?.count ?? 0))" }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    static func describe(_ explanation: RulesExplanation) -> String {
        let pr = explanation.pr
        var out = "\(pr.nameWithOwner)#\(pr.number) \(pr.title) (head \(pr.headSha.prefix(7)))\n\n"
        out += "## select\n\n\(explanation.select)\n\n## decide\n\n"
        out += explanation.decide ?? "PRBar holds no completed review of this commit, so there is nothing to decide yet."
        return out
    }
}
