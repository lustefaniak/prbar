import Foundation

/// `prbar-review rules check | explain <pr>`: the rules directory from the
/// outside. `check` compiles it here, without a server, so an edit can be
/// tried before PRBar picks it up; `explain` asks the server, which holds
/// the PR and its review, why the rules decide what they do.
///
/// Exit status: 0 fine, 1 the rules don't compile, 2 bad arguments,
/// 3 no reachable server.
enum RulesCommand: Equatable {
    case check(configPath: String?)
    case explain(PRReference, configPath: String?)
    case history(Filter, limit: Int, json: Bool)
    /// One recorded evaluation (by id prefix), or every one the filter keeps.
    case replay(id: String?, Filter, watch: Bool, configPath: String?)
    /// The JSON schema of a rules file, for editors.
    case schema(RuleSchema.File)

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
            case "--limit":
                guard let v = value(), let n = Int(v), n > 0 else { return nil }
                limit = n
            case "--json":
                json = true
            case "--watch":
                watch = true
            case let flag where flag.hasPrefix("-"):
                return nil
            default:
                positional.append(args[i])
            }
            i += 1
        }
        switch args[1] {
        case "check" where positional.isEmpty:
            self = .check(configPath: configPath)
        case "explain" where positional.count == 1:
            guard let target = Invocation.parseTarget(positional[0]) else { return nil }
            self = .explain(PRReference(owner: target.owner, repo: target.repo, number: target.number), configPath: configPath)
        case "schema" where positional.count == 1:
            guard let file = RuleSchema.File(rawValue: positional[0]) else { return nil }
            self = .schema(file)
        case "history" where positional.isEmpty:
            self = .history(filter, limit: limit, json: json)
        case "replay" where positional.count <= 1:
            self = .replay(id: positional.first, filter, watch: watch, configPath: configPath)
        default:
            return nil
        }
    }

    static let usage = """
    usage: prbar-review rules check [--config <path>]
           prbar-review rules explain <pr-url|owner/repo#number> [--config <path>]
           prbar-review rules history [--pr <pr>] [--days <n>] [--limit <n>] [--json]
           prbar-review rules replay [<id>] [--pr <pr>] [--days <n>] [--watch] [--config <path>]
           prbar-review rules schema select|decide|lists

    The rules live in `rules/` beside prbar.yaml (or $PRBAR_RULES):

      rules/lists.yaml        named lists, e.g. `trusted: [alice, bob]`
      rules/select/*.yaml     whether to review a PR at all
      rules/decide/*.yaml     what to post once it is reviewed

    Each file is a CEL policy in cel-go's format. Files run in name order;
    the first one that matches decides, and when none does the repo settings
    in prbar.yaml decide as before.

      check     compile the rules here and list them, or say what's wrong
      explain   ask the running PRBar why it reviews a PR or not, and what
                it posts for the review it holds: every condition, with the
                facts it read
      history   the rule evaluations PRBar recorded, newest first: each
                keeps the exact facts the rules saw
      replay    run the rules as they are now on recorded facts. With an id
                (a prefix from `history` is enough): every condition, and
                whether the answer changed since. Without one: every
                evaluation in the last --days (7), listing the answers your
                edits would change. --watch replays again on every save
      schema    the JSON schema of a rules file, which editors use to
                complete and check it; also published at
                \(RuleSchema.baseURL)<file>.schema.json

    """

    @MainActor
    func run(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        print: (String) -> Void = { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
        fail: (String) -> Void = { FileHandle.standardError.write(Data("prbar-review: \($0)\n".utf8)) }
    ) async -> Int32 {
        switch self {
        case .check(let configPath):
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

        case let .replay(id, filter, watch, configPath):
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
                let fingerprint = RuleDirectory.fingerprint(directory)
                if fingerprint != seen {
                    if seen != nil { print("\n--- \(Self.timestamp(Date())): the rules changed\n") }
                    seen = fingerprint
                    let rules: Rules?
                    do {
                        rules = try RuleDirectory.load(directory)
                        if let target {
                            print(Self.describe(RuleReplay.replay(target, rules: rules), rules: rules, explain: true))
                        } else {
                            let results = Self.evaluations(filter, environment: environment).map { RuleReplay.replay($0, rules: rules) }
                            print(Self.summary(results, days: filter.days, directory: directory))
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

        case let .explain(ref, configPath):
            let configFile = try? CLIConfig.locate(path: configPath, environment: environment)
            let connected: ServerConnection.Connected
            do {
                connected = try await ClientReview.launcher(configFile: configFile)()
            } catch {
                fail("cannot reach the PRBar server: \(error.localizedDescription)")
                return 3
            }
            defer { connected.client.close() }
            do {
                let explanation = try await connected.client.call(
                    .explainRules, ExplainRulesParams(pr: ref), as: RulesExplanation.self)
                print(Self.describe(explanation))
                return 0
            } catch {
                fail(error.localizedDescription)
                return 1
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
        "\(evaluation.id.uuidString.prefix(8).lowercased())  \(timestamp(evaluation.at))  \(evaluation.stage.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0))  \(evaluation.pr)  \(evaluation.outcome)"
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

    static func summary(_ results: [RuleReplay.Result], days: Int, directory: URL) -> String {
        let changed = results.filter(\.changed)
        var lines = [
            "Replayed \(results.count) evaluation\(results.count == 1 ? "" : "s") from the last \(days) day\(days == 1 ? "" : "s") with the rules in \(directory.path): \(changed.isEmpty ? "no answer changes." : "\(changed.count) would change.")",
        ]
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
