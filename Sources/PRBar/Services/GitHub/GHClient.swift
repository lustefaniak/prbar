import Foundation

actor GHClient {
    enum GHError: Error, LocalizedError, Sendable {
        case ghNotFound
        case execFailed(stderr: String, exitCode: Int32)
        case decodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .ghNotFound:
                return "gh CLI not found. Install via: brew install gh, then `gh auth login`."
            case .execFailed(let stderr, let code):
                let snippet = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return "gh exited \(code): \(snippet.prefix(400))"
            case .decodingFailed(let msg):
                return "decode error: \(msg.prefix(400))"
            }
        }
    }

    private let executablePath: String

    init() throws {
        guard let path = ExecutableResolver.find("gh") else {
            throw GHError.ghNotFound
        }
        self.executablePath = path
    }

    func fetchInbox() async throws -> [InboxPR] {
        let result = try await ProcessRunner.run(
            executable: executablePath,
            args: ["api", "graphql", "-f", "query=\(GraphQLQueries.inbox)"]
        )

        guard result.succeeded else {
            throw GHError.execFailed(
                stderr: result.stderrString ?? "",
                exitCode: result.exitCode
            )
        }

        let response: InboxResponse
        do {
            response = try JSONDecoder().decode(InboxResponse.self, from: result.stdout)
        } catch {
            throw GHError.decodingFailed(String(describing: error))
        }

        let viewerLogin = response.data.viewer.login
        return response.data.search.edges.map {
            InboxPR(node: $0.node, viewerLogin: viewerLogin)
        }
    }

    /// Fetch the viewer's authored open PRs via `viewer.pullRequests`.
    /// Independent of GitHub Search, so it keeps working when search
    /// indexing is lagging or returning empty for `involves:@me`.
    func fetchMyPRs() async throws -> [InboxPR] {
        let result = try await ProcessRunner.run(
            executable: executablePath,
            args: ["api", "graphql", "-f", "query=\(GraphQLQueries.myPRs)"]
        )

        guard result.succeeded else {
            throw GHError.execFailed(
                stderr: result.stderrString ?? "",
                exitCode: result.exitCode
            )
        }

        let response: MyPRsResponse
        do {
            response = try JSONDecoder().decode(MyPRsResponse.self, from: result.stdout)
        } catch {
            throw GHError.decodingFailed(String(describing: error))
        }

        let viewerLogin = response.data.viewer.login
        return response.data.viewer.pullRequests.nodes.map {
            InboxPR(node: $0, viewerLogin: viewerLogin)
        }
    }

    /// Refresh a single PR. Costs ~1 GraphQL point vs ~25 for fetchInbox.
    func fetchPR(owner: String, repo: String, number: Int) async throws -> InboxPR {
        let result = try await ProcessRunner.run(
            executable: executablePath,
            args: [
                "api", "graphql",
                "-F", "owner=\(owner)",
                "-F", "name=\(repo)",
                "-F", "number=\(number)",
                "-f", "query=\(GraphQLQueries.singlePR)",
            ]
        )

        guard result.succeeded else {
            throw GHError.execFailed(
                stderr: result.stderrString ?? "",
                exitCode: result.exitCode
            )
        }

        let response: SinglePRResponse
        do {
            response = try JSONDecoder().decode(SinglePRResponse.self, from: result.stdout)
        } catch {
            throw GHError.decodingFailed(String(describing: error))
        }

        return InboxPR(
            node: response.data.repository.pullRequest,
            viewerLogin: response.data.viewer.login
        )
    }

    /// Fetch the unified diff for a PR via `gh pr diff`. Returns the raw
    /// diff text; caller is responsible for parsing. Cache key should be
    /// (owner, repo, number, headSha).
    func fetchDiff(owner: String, repo: String, number: Int) async throws -> String {
        let result = try await ProcessRunner.run(
            executable: executablePath,
            args: ["pr", "diff", "\(number)", "--repo", "\(owner)/\(repo)"]
        )
        guard result.succeeded else {
            throw GHError.execFailed(
                stderr: result.stderrString ?? "",
                exitCode: result.exitCode
            )
        }
        return result.stdoutString ?? ""
    }

    /// Fetch the raw log for a single failed Actions job. Uses the
    /// REST endpoint `repos/{o}/{r}/actions/jobs/{jobId}/logs` (302 →
    /// short-lived signed URL → plain text). `gh api` follows the
    /// redirect and returns the log body on stdout. Caller should tail
    /// the result; full logs can be megabytes.
    func fetchJobLog(owner: String, repo: String, jobId: Int64) async throws -> String {
        let result = try await ProcessRunner.run(
            executable: executablePath,
            args: [
                "api",
                "repos/\(owner)/\(repo)/actions/jobs/\(jobId)/logs",
            ]
        )
        guard result.succeeded else {
            throw GHError.execFailed(
                stderr: result.stderrString ?? "",
                exitCode: result.exitCode
            )
        }
        return result.stdoutString ?? ""
    }

    /// Submit a review (approve / comment / request changes) on a PR.
    /// Body can be empty for plain approvals; some workflows want a short
    /// note even on approve (gh accepts an empty body string).
    func postReview(
        owner: String,
        repo: String,
        number: Int,
        kind: ReviewActionKind,
        body: String
    ) async throws {
        var args: [String] = [
            "pr", "review", "\(number)",
            "--repo", "\(owner)/\(repo)",
            kind.ghFlag,
        ]
        if !body.isEmpty {
            args.append(contentsOf: ["--body", body])
        }

        let result = try await ProcessRunner.run(
            executable: executablePath,
            args: args
        )
        guard result.succeeded else {
            throw GHError.execFailed(
                stderr: result.stderrString ?? "",
                exitCode: result.exitCode
            )
        }
    }

    /// Merge a pull request. Throws GHError.execFailed on any non-zero exit
    /// (which includes "PR not mergeable" and "approval required" — gh's
    /// stderr text is descriptive and surfaces in lastError as-is).
    func mergePR(
        owner: String,
        repo: String,
        number: Int,
        method: MergeMethod,
        deleteBranch: Bool = false
    ) async throws {
        var args: [String] = [
            "pr", "merge", "\(number)",
            "--repo", "\(owner)/\(repo)",
            method.ghFlag,
        ]
        if deleteBranch {
            args.append("--delete-branch")
        }

        let result = try await ProcessRunner.run(
            executable: executablePath,
            args: args
        )
        guard result.succeeded else {
            throw GHError.execFailed(
                stderr: result.stderrString ?? "",
                exitCode: result.exitCode
            )
        }
    }
}
