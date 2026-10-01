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

    init?(args: [String]) {
        guard args.first == "rules", args.count >= 2 else { return nil }
        var configPath: String?
        var positional: [String] = []
        var i = 2
        while i < args.count {
            if args[i] == "--config" {
                i += 1
                guard i < args.count else { return nil }
                configPath = args[i]
            } else if args[i].hasPrefix("-") {
                return nil
            } else {
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
        default:
            return nil
        }
    }

    static let usage = """
    usage: prbar-review rules check [--config <path>]
           prbar-review rules explain <pr-url|owner/repo#number> [--config <path>]

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
