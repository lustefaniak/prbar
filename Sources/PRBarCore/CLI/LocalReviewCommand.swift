import Foundation

/// `prbar-review <dir>`: an AI review of work in progress, before it is a
/// PR. The working tree's uncommitted and unpushed changes against where
/// its branch forked, reviewed by the PRBar server under the rules
/// `prbar.yaml` has for that repository (matched by its `origin` remote)
/// and, in a monorepo, for each subfolder the change touches. Nothing is
/// posted anywhere; the review is printed.
@MainActor
struct LocalReviewCommand {
    struct Options: Equatable {
        var path: String
        var base: String?
        var provider: ProviderID?
        var force = false
        var configPath: String?
        var json = false

        /// Nil unless the one positional argument is a directory, so a PR
        /// reference never lands here.
        init?(args: [String], isDirectory: (String) -> Bool = Self.isDirectory) {
            var positional: String?
            var i = args.startIndex
            while i < args.endIndex {
                switch args[i] {
                case "--force":
                    force = true
                case "--json":
                    json = true
                case "--base", "--provider", "--config":
                    let flag = args[i]
                    i += 1
                    guard i < args.endIndex else { return nil }
                    switch flag {
                    case "--base": base = args[i]
                    case "--config": configPath = args[i]
                    default:
                        guard let p = ProviderID(rawValue: args[i]) else { return nil }
                        provider = p
                    }
                default:
                    guard !args[i].hasPrefix("-"), positional == nil else { return nil }
                    positional = args[i]
                }
                i += 1
            }
            guard let positional, isDirectory(positional) else { return nil }
            path = (positional as NSString).expandingTildeInPath
        }

        nonisolated static func isDirectory(_ path: String) -> Bool {
            var dir: ObjCBool = false
            return FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath, isDirectory: &dir) && dir.boolValue
        }
    }

    var options: Options
    var configFile: URL?
    var connect: @Sendable () async throws -> ServerConnection.Connected
    var print: (String) -> Void = { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) }
    var log: (String) -> Void = { FileHandle.standardError.write(Data("prbar-review: \($0)\n".utf8)) }
    var pollInterval: Duration = .milliseconds(500)

    /// 0 with a review printed (whatever its verdict), 1 when the review
    /// failed, 2 when it couldn't be started.
    func run() async -> Int32 {
        let client: APIClient
        do {
            client = try await connect().client
        } catch {
            log("cannot reach the PRBar server: \(error.localizedDescription)")
            return 2
        }
        defer { client.close() }
        if let configFile {
            guard let status = try? await client.call(.status, as: ServerStatus.self) else {
                log("cannot reach the PRBar server")
                return 2
            }
            if !ClientReview.sameFile(configFile.path, status.configPath) {
                log("the running PRBar server reads \(status.configPath), not \(configFile.path); stop it to review with \(configFile.path)")
                return 2
            }
        }

        let started: ReviewResult
        do {
            started = try await client.call(.reviewLocal, LocalReviewParams(
                path: options.path, base: options.base, provider: options.provider, force: options.force), as: ReviewResult.self)
        } catch {
            log(error.localizedDescription)
            return 2
        }
        let pr = started.pr
        guard let local = pr.local else {
            log("the server answered without a local review")
            return 2
        }
        if let ignored = started.ignored {
            print("Not reviewed: \(ignored).")
            return 0
        }
        log("reviewing \(local.changedFiles) changed file\(local.changedFiles == 1 ? "" : "s") on \(local.branch) against \(local.baseRef) (\(local.baseSha.prefix(7)))")

        var outcome: ReviewOutcome
        do {
            while true {
                outcome = try await client.call(
                    .reviewOutcome, ReviewOutcomeParams(pr: PRReference(nodeId: pr.nodeId), since: Date()),
                    as: ReviewOutcome.self)
                if outcome.settled { break }
                try await Task.sleep(for: pollInterval)
            }
        } catch {
            log("lost the PRBar server mid-review: \(error.localizedDescription)")
            return 1
        }

        guard let state = outcome.review else {
            log("the review state vanished")
            return 1
        }
        switch state.status {
        case .completed(let review):
            if options.json {
                let output = ReviewOutput(
                    task_id: local.root, head_sha: state.headSha, provider: state.providerId.rawValue,
                    posted: false, review: review)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                print((try? encoder.encode(output)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
            } else {
                print("Review of local changes on \(local.branch) against \(local.baseRef), by \(state.providerId.rawValue): "
                    + MCPText.completed(review, full: true))
            }
            return 0
        case .failed(let message):
            log("the review failed: \(message)")
            return 1
        case .skipped(let reason):
            print("Not reviewed: \(reason.detail)")
            return 0
        case .queued, .running:
            log("the review was still running")
            return 1
        }
    }
}
