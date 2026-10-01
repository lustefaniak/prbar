import Foundation

/// `prbar-review <pr>` as a client of the PRBar server: the review runs in
/// the one process that runs every other review (the app's, a `serve`, or
/// one started here on demand), so it shares the queue, the review state,
/// the history and the verdict marker with every other surface, and the
/// app shows it while it runs. The NDJSON on stdout is the same as the
/// standalone run's: a `started` event, then one terminal event.
///
/// The server applies the same gates the standalone run did (`gated`), and
/// posts through its action queue. This process waits until the review and
/// every post it set off are done, so the terminal event still means the
/// work landed.
@MainActor
struct ClientReview {
    var invocation: Invocation
    /// The config file this invocation resolves to, nil for none. A running
    /// server reading another one would review by different rules.
    var configFile: URL?
    var connect: @Sendable () async throws -> ServerConnection.Connected
    var emit: (BrahmandaEvent) -> Void = { $0.emit() }
    var writeReview: (ReviewOutput, String) throws -> Void = { try $0.write(to: $1) }
    var log: (String) -> Void = { FileHandle.standardError.write(Data("prbar-review: \($0)\n".utf8)) }
    var pollInterval: Duration = .milliseconds(500)

    /// How long a server started for one review waits for the next client.
    nonisolated static let onDemandIdleSeconds = 300

    /// Reaches the server, starting this binary as an on-demand one when
    /// nothing answers. The cost cap stays off there, as in the standalone
    /// run: an orchestrator's budget owns spend.
    nonisolated static func launcher(configFile: URL?) -> @Sendable () async throws -> ServerConnection.Connected {
        let state = ConfigLocation.stateDirectory()
        var arguments = ["serve", "--idle-exit", String(onDemandIdleSeconds), "--daily-cap", "off"]
        if let configFile { arguments += ["--config", configFile.path] }
        let executable = ServerLauncher.Executable(
            path: Bundle.main.executablePath ?? CommandLine.arguments[0],
            arguments: arguments,
            log: state.appendingPathComponent("server.log"))
        return {
            try await ServerLauncher.connect(
                socketURL: ServerLocation.socketURL(stateDirectory: state),
                client: "prbar-review", executable: executable)
        }
    }

    func run() async -> Int32 {
        let target = invocation.target
        let taskId = "\(target.owner)/\(target.repo)#\(target.number)"

        let client: APIClient
        do {
            client = try await connect().client
        } catch {
            log("cannot reach the PRBar server: \(error.localizedDescription)")
            return 2
        }
        defer { client.close() }

        if let configFile {
            do {
                let status = try await client.call(.status, as: ServerStatus.self)
                if !Self.sameFile(configFile.path, status.configPath) {
                    log("the running PRBar server reads \(status.configPath), not \(configFile.path); pass --standalone to review with \(configFile.path) in this process")
                    return 2
                }
            } catch {
                log("cannot reach the PRBar server: \(error.localizedDescription)")
                return 2
            }
        }

        let since = Date()
        let started: ReviewResult
        do {
            started = try await client.call(.runReview, RunReviewParams(
                pr: PRReference(owner: target.owner, repo: target.repo, number: target.number),
                provider: invocation.providerOverride,
                force: invocation.force,
                fetch: true,
                gated: true), as: ReviewResult.self)
        } catch {
            // Nothing was reviewed, but the task id is known, so say so as
            // an event rather than a silent non-zero exit.
            emit(BrahmandaEvent(taskId: taskId, outcome: .failed, note: "review not started: \(error.localizedDescription)"))
            return 1
        }
        let pr = started.pr
        let runtime = (started.provider ?? invocation.providerOverride ?? .claude).rawValue
        emit(BrahmandaEvent(
            taskId: taskId, outcome: .started, note: "\(pr.headSha.prefix(7)) \(pr.title)",
            agent: .init(runtime: runtime, session_id: nil, cost_usd: nil)))

        if let ignored = started.ignored {
            emit(BrahmandaEvent(
                taskId: taskId, outcome: .succeeded, note: "not reviewed: \(ignored)",
                agent: .init(runtime: runtime, session_id: nil, cost_usd: nil)))
            return 0
        }

        var outcome: ReviewOutcome
        do {
            while true {
                outcome = try await client.call(
                    .reviewOutcome, ReviewOutcomeParams(pr: PRReference(nodeId: pr.nodeId), since: since),
                    as: ReviewOutcome.self)
                if outcome.settled { break }
                try await Task.sleep(for: pollInterval)
            }
        } catch {
            emit(BrahmandaEvent(
                taskId: taskId, outcome: .failed, note: "lost the PRBar server mid-review: \(error.localizedDescription)",
                agent: .init(runtime: runtime, session_id: nil, cost_usd: nil)))
            return 0
        }

        // A gated run queues a fresh review synchronously, so one that is
        // already complete in the reply was answered from an earlier run.
        let cached: Bool
        if let state = started.review, case .completed = state.status { cached = true } else { cached = false }
        let report = Self.report(outcome, cached: cached)
        var outputFailure: String?
        if let path = invocation.reviewJsonPath, let state = outcome.review, case .completed(let review) = state.status {
            do {
                try writeReview(ReviewOutput(
                    task_id: taskId, head_sha: state.headSha, provider: state.providerId.rawValue,
                    posted: report.posted, review: review), path)
            } catch {
                // With the auto gates off this file is the only durable
                // output, so a success here would claim findings that are lost.
                outputFailure = "could not write \(path): \(error.localizedDescription)"
                log(outputFailure!)
            }
        }
        emit(BrahmandaEvent(
            taskId: taskId,
            outcome: (report.isFailure || outputFailure != nil) ? .failed : .succeeded,
            note: outputFailure.map { "\(report.note); \($0)" } ?? report.note,
            agent: .init(runtime: (outcome.review?.providerId.rawValue) ?? runtime, session_id: nil, cost_usd: report.costUsd)))
        return 0
    }

    struct Report: Equatable {
        var isFailure: Bool
        var note: String
        var costUsd: Double?
        var posted = false
    }

    /// The terminal event's content, worded as the standalone run words it.
    static func report(_ outcome: ReviewOutcome, cached earlier: Bool) -> Report {
        guard let state = outcome.review else {
            return Report(isFailure: true, note: "review state vanished")
        }
        // A review from an earlier run (the same commit, reviewed already)
        // costs nothing now; reporting its cost again would bill it twice.
        func cost(_ value: Double) -> Double? { earlier || value <= 0 ? nil : value }
        switch state.status {
        case .skipped(let reason):
            return Report(isFailure: false, note: "skipped: \(reason.short)")
        case .failed(let message):
            return Report(isFailure: true, note: message, costUsd: cost(state.costUsd))
        case .queued, .running:
            return Report(isFailure: true, note: "still running at exit", costUsd: cost(state.costUsd))
        case .completed(let review):
            var parts = ["\(review.verdict.rawValue) (confidence \(Int((review.confidence * 100).rounded()))%)"]
            parts.append("\(review.annotations.count) findings")
            if earlier { parts.append("reviewed earlier at this commit") }
            // Retries log one row per attempt, so the last word is a
            // success if any attempt landed.
            let posts = outcome.actions.filter { $0.kind != .reviewReRequested && $0.kind != .autoResolveThreads }
            let post = posts.last { $0.outcome == .success } ?? posts.last
            if let post {
                parts.append(post.outcome == .success
                    ? "posted \(post.kind.rawValue)"
                    : "post failed: \(post.errorMessage ?? "unknown")")
            } else if outcome.flagged {
                parts.append("flagged, nothing posted")
            } else {
                parts.append("nothing posted (no gate fired)")
            }
            if review.isSubscriptionAuth { parts.append("cost is API-equivalent (subscription auth)") }
            return Report(
                isFailure: post?.outcome == .failure, note: parts.joined(separator: "; "),
                costUsd: cost(review.costUsd), posted: post?.outcome == .success)
        }
    }

    nonisolated static func sameFile(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).standardizedFileURL.resolvingSymlinksInPath().path
            == URL(fileURLWithPath: b).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
