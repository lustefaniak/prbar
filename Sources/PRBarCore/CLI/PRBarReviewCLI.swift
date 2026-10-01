import Foundation

/// Headless entry point: review one PR, post whatever the repo's auto
/// gates allow, report what happened as brahmanda NDJSON, exit.
///
/// Deliberately *only* the review. Selecting which PRs to review,
/// claiming them across concurrent workers, retrying, and not
/// re-dispatching a PR that already failed at this head SHA are the
/// orchestrator's job — it has a journal and a scheduler, and this
/// process has neither.
///
/// Exit status is for setup failures only (bad arguments, missing `gh`,
/// unreadable config): those produce no event, so brahmanda's runner
/// synthesizes one from the stderr tail. A review that ran and failed is
/// a *successful* worker run reporting `outcome: failed`, and exits 0.
public enum PRBarReviewCLI {
    public static func main() async -> Int32 {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "serve" || args.first == "watch" {
            guard let options = ServeCommand.Options(args: Array(args.dropFirst())) else {
                FileHandle.standardError.write(Data(ServeCommand.usage.utf8))
                return 2
            }
            return await ServeCommand.run(options)
        }
        if args.first == "mcp" {
            guard args.count == 1 else {
                FileHandle.standardError.write(Data(MCPCommand.usage.utf8))
                return 2
            }
            return await MCPCommand.run()
        }
        if args.first == "rules" {
            guard let command = RulesCommand(args: args) else {
                FileHandle.standardError.write(Data(RulesCommand.usage.utf8))
                return 2
            }
            return await command.run()
        }
        if let name = args.first, ClientCommand.names.contains(name) {
            guard let command = ClientCommand(args: args) else {
                FileHandle.standardError.write(Data(ClientCommand.usage.utf8))
                return 2
            }
            return await command.run()
        }
        guard let invocation = Invocation(args: args) else {
            if let local = LocalReviewCommand.Options(args: args) {
                let configFile: URL?
                do {
                    configFile = try CLIConfig.locate(path: local.configPath)
                    _ = try CLIConfig.load(path: local.configPath)
                } catch {
                    FileHandle.standardError.write(Data("prbar-review: \(error.localizedDescription)\n".utf8))
                    return 2
                }
                return await reviewLocal(local, configFile: configFile)
            }
            FileHandle.standardError.write(Data(Self.usage.utf8))
            return 2
        }
        if !invocation.standalone {
            // Loaded here only to fail fast on a broken file; the server
            // reads it itself.
            let configFile: URL?
            do {
                configFile = try CLIConfig.locate(path: invocation.configPath)
                _ = try CLIConfig.load(path: invocation.configPath)
            } catch {
                FileHandle.standardError.write(Data("prbar-review: \(error.localizedDescription)\n".utf8))
                return 2
            }
            return await client(invocation, configFile: configFile)
        }
        return await standalone(invocation)
    }

    @MainActor
    static func reviewLocal(_ options: LocalReviewCommand.Options, configFile: URL?) async -> Int32 {
        await LocalReviewCommand(
            options: options, configFile: configFile,
            connect: ClientReview.launcher(configFile: configFile)
        ).run()
    }

    @MainActor
    static func client(_ invocation: Invocation, configFile: URL?) async -> Int32 {
        await ClientReview(
            invocation: invocation, configFile: configFile,
            connect: ClientReview.launcher(configFile: configFile)
        ).run()
    }

    /// The review in this process, as before the server existed.
    @MainActor
    static func standalone(_ invocation: Invocation) async -> Int32 {
        let config: PRBarConfig
        do {
            config = try CLIConfig.load(path: invocation.configPath)
        } catch {
            FileHandle.standardError.write(
                Data("prbar-review: \(error.localizedDescription)\n".utf8))
            return 2
        }

        let client: GHClient
        do {
            client = try GHClient()
        } catch {
            FileHandle.standardError.write(
                Data("prbar-review: \(error.localizedDescription)\n".utf8))
            return 2
        }

        let target = invocation.target
        let taskId = "\(target.owner)/\(target.repo)#\(target.number)"

        let pr: InboxPR
        do {
            pr = try await client.fetchPR(
                owner: target.owner, repo: target.repo, number: target.number)
        } catch {
            // The PR could not be read at all, so nothing was reviewed —
            // a setup-shaped failure, but we know the task id, so report
            // it as one rather than leaving a silent non-zero exit.
            BrahmandaEvent(taskId: taskId, outcome: .failed,
                           note: "fetch failed: \(error.localizedDescription)").emit()
            return 1
        }

        // Same precedence the worker uses, so the runtime reported to
        // brahmanda's budget ledger is the one that actually spends.
        let resolved = config.resolver()(target.owner, target.repo)
        let providerId = invocation.providerOverride
            ?? resolved.providerOverride
            ?? config.defaultProvider.resolve()
        BrahmandaEvent(
            taskId: taskId, outcome: .started,
            note: "\(pr.headSha.prefix(7)) \(pr.title)",
            agent: .init(runtime: providerId.rawValue, session_id: nil, cost_usd: nil)
        ).emit()

        let runner = Runner(
            config: config,
            diffFetcher: { owner, repo, number in
                try await client.fetchDiff(owner: owner, repo: repo, number: number)
            },
            reviewThreadFetcher: { owner, repo, number in
                try await client.fetchReviewThreads(owner: owner, repo: repo, number: number)
            },
            lazyFactFetcher: LazyFactFetcher(client),
            repoRulesFetcher: { owner, repo in try await client.fetchRepoRules(owner: owner, repo: repo) },
            reviewPoster: { pr, kind, body, comments in
                if comments.isEmpty {
                    try await client.postReview(
                        owner: pr.owner, repo: pr.repo, number: pr.number,
                        kind: kind, body: body
                    )
                } else {
                    try await client.postReviewWithComments(
                        owner: pr.owner, repo: pr.repo, number: pr.number,
                        event: kind.apiEvent, body: body, comments: comments,
                        // The SHA the review actually read, not current head
                        // — same reason as every other post path.
                        commitId: pr.headSha
                    )
                }
            },
            reviewerRequester: { pr, login in
                try await client.requestReviewer(
                    owner: pr.owner, repo: pr.repo, number: pr.number, login: login
                )
            },
            threadResolver: { threadId in
                try await client.resolveReviewThread(threadId: threadId)
            }
        )
        let outcome = await runner.review(
            pr: pr, force: invocation.force, providerOverride: invocation.providerOverride)

        // Before the terminal event, so that event stays the last line.
        var outputFailure: String?
        if let path = invocation.reviewJsonPath, let review = outcome.review {
            do {
                try ReviewOutput(
                    task_id: taskId, head_sha: pr.headSha,
                    provider: (outcome.providerId ?? providerId).rawValue,
                    posted: outcome.posted, review: review
                ).write(to: path)
            } catch {
                // With the auto gates off this file is the *only* durable
                // output, so reporting success here would tell the
                // orchestrator the work landed while the findings it paid
                // for are gone.
                outputFailure = "could not write \(path): \(error.localizedDescription)"
                FileHandle.standardError.write(Data("prbar-review: \(outputFailure!)\n".utf8))
            }
        }

        BrahmandaEvent(
            taskId: taskId,
            outcome: (outcome.isFailure || outputFailure != nil) ? .failed : .succeeded,
            note: outputFailure.map { "\(outcome.note); \($0)" } ?? outcome.note,
            agent: .init(runtime: (outcome.providerId ?? providerId).rawValue,
                         session_id: outcome.sessionId, cost_usd: outcome.costUsd)
        ).emit()
        return 0
    }

    static let usage = """
    usage: prbar-review [options] <pr-url|owner/repo#number>

      --force                 review even when a repo gate (draft, already
                              reviewed, an AI verdict already at this SHA)
                              would otherwise skip it
      --provider claude|codex override the configured provider
      --config <path>         prbar.yaml (JSON works too); defaults to
                              $PRBAR_CONFIG, then ./prbar.yaml, ./prbar.json,
                              then ~/.config/prbar/prbar.yaml (the app's)
      --review-json <path>    write the full review (summary, findings,
                              cost) as one JSON line; - means stdout.
                              Without it, only the verdict and a finding
                              count reach the event stream
      --standalone            review in this process instead of through the
                              PRBar server

    Reviews through the running PRBar server (the app or `prbar-review
    serve`), so the app shows it and its history keeps it. With none
    running, starts one that exits after 5 idle minutes and leaves the rest
    of the inbox alone. Emits brahmanda NDJSON on stdout, one event per
    line. Logs go to stderr.

    prbar-review [--base <ref>] [--provider claude|codex] [--force] [--json] <dir>
                                   review the uncommitted and unpushed work in
                                   a checkout against where its branch forked,
                                   under that repo's rules; prints the review
                                   (one JSON line with --json), posts nothing
    prbar-review serve [options]   run the PRBar server headless;
                                   see `prbar-review serve --help`
    prbar-review status | inbox | history | events
                                   ask the running server; see
                                   `prbar-review status --help`
    prbar-review rules check | explain <pr>
                                   check the rules directory, or ask why
                                   they decide what they do for a PR; see
                                   `prbar-review rules --help`
    prbar-review mcp               serve PRBar to a coding agent over MCP
    """
}
