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
        guard let invocation = Invocation(args: args) else {
            FileHandle.standardError.write(Data(Self.usage.utf8))
            return 2
        }

        let config: CLIConfig
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
            ?? config.defaultProvider
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
            reviewPoster: { pr, kind, body, comments in
                if comments.isEmpty {
                    try await client.postReview(
                        owner: pr.owner, repo: pr.repo, number: pr.number,
                        kind: kind, body: body
                    )
                } else {
                    try await client.postReviewWithComments(
                        owner: pr.owner, repo: pr.repo, number: pr.number,
                        event: kind.apiEvent, body: body, comments: comments
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
      --config <path>         JSON settings file; defaults to
                              $PRBAR_CONFIG, then ./prbar.json
      --review-json <path>    write the full review (summary, findings,
                              cost) as one JSON line; - means stdout.
                              Without it, only the verdict and a finding
                              count reach the event stream

    Emits brahmanda NDJSON on stdout, one event per line. Logs go to stderr.
    """
}
