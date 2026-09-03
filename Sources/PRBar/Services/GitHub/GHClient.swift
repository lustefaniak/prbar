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

    /// Every review thread on a PR, plus the viewer's login and the head
    /// commit the threads were read against.
    ///
    /// Fetched on demand rather than folded into the inbox query — see
    /// `GraphQLQueries.reviewThreads`. Pages until GitHub stops handing
    /// back a cursor: a truncated list would silently leave threads
    /// unconsidered on exactly the long-running PRs that accumulate them.
    func fetchReviewThreads(
        owner: String,
        repo: String,
        number: Int
    ) async throws -> ReviewThreadPage {
        var threads: [ReviewThread] = []
        var viewerLogin = ""
        var headRefOid = ""
        var cursor: String?
        // Bounded so a cursor GitHub never terminates can't spin forever.
        for _ in 0..<20 {
            var args = [
                "api", "graphql",
                "-F", "owner=\(owner)",
                "-F", "name=\(repo)",
                "-F", "number=\(number)",
            ]
            if let cursor { args += ["-F", "after=\(cursor)"] }
            args += ["-f", "query=\(GraphQLQueries.reviewThreads)"]
            let result = try await ProcessRunner.run(executable: executablePath, args: args)
            guard result.succeeded else {
                throw GHError.execFailed(
                    stderr: result.stderrString ?? "",
                    exitCode: result.exitCode
                )
            }
            let response: ReviewThreadsResponse
            do {
                response = try JSONDecoder().decode(ReviewThreadsResponse.self, from: result.stdout)
            } catch {
                throw GHError.decodingFailed(String(describing: error))
            }
            let pr = response.data.repository.pullRequest
            viewerLogin = response.data.viewer.login
            headRefOid = pr.headRefOid
            threads += pr.reviewThreads.nodes.map { node in
                ReviewThread(
                    id: node.id,
                    isResolved: node.isResolved,
                    isOutdated: node.isOutdated,
                    path: node.path ?? "",
                    comments: node.comments.nodes.map {
                        ReviewThread.Comment(authorLogin: $0.author?.login ?? "", body: $0.body)
                    }
                )
            }
            guard pr.reviewThreads.pageInfo.hasNextPage,
                  let next = pr.reviewThreads.pageInfo.endCursor
            else { break }
            cursor = next
        }
        return ReviewThreadPage(threads: threads, viewerLogin: viewerLogin, headRefOid: headRefOid)
    }

    /// Mark a review thread resolved. Idempotent on GitHub's side —
    /// resolving an already-resolved thread is not an error.
    func resolveReviewThread(threadId: String) async throws {
        let mutation = """
        mutation Resolve($id: ID!) {
          resolveReviewThread(input: {threadId: $id}) { thread { isResolved } }
        }
        """
        let result = try await ProcessRunner.run(
            executable: executablePath,
            args: ["api", "graphql", "-F", "id=\(threadId)", "-f", "query=\(mutation)"]
        )
        guard result.succeeded else {
            throw GHError.execFailed(
                stderr: result.stderrString ?? "",
                exitCode: result.exitCode
            )
        }
    }

    private struct ReviewThreadsResponse: Decodable {
        let data: DataField
        struct DataField: Decodable {
            let viewer: Viewer
            let repository: Repository
        }
        struct Viewer: Decodable { let login: String }
        struct Repository: Decodable { let pullRequest: PullRequest }
        struct PullRequest: Decodable {
            let headRefOid: String
            let reviewThreads: ThreadList
        }
        struct ThreadList: Decodable {
            let pageInfo: PageInfo
            let nodes: [ThreadNode]
        }
        struct PageInfo: Decodable {
            let hasNextPage: Bool
            let endCursor: String?
        }
        struct ThreadNode: Decodable {
            let id: String
            let isResolved: Bool
            let isOutdated: Bool
            /// Null when the viewer can't see the file the thread anchors to.
            let path: String?
            let comments: CommentList
        }
        struct CommentList: Decodable { let nodes: [CommentNode] }
        struct CommentNode: Decodable {
            let author: Author?
            let body: String
        }
        struct Author: Decodable { let login: String }
    }

    /// Re-add `login` to a PR's requested reviewers.
    ///
    /// Exists because GitHub silently drops you from `reviewRequests` the
    /// moment you submit *any* review — COMMENT included, and with no
    /// `review_request_removed` timeline event to show for it. A shared-
    /// findings post is therefore indistinguishable, to GitHub, from you
    /// having reviewed the PR: it leaves your requested-reviewer list, drops
    /// out of PRBar's inbox (role flips to `.other`), and never gets
    /// retriaged when the author pushes a fix. Re-requesting immediately
    /// after the post restores the state the user actually intended.
    ///
    /// Self-re-request is permitted by the API after a COMMENT review
    /// (verified against a live PR).
    func requestReviewer(
        owner: String,
        repo: String,
        number: Int,
        login: String
    ) async throws {
        guard !login.isEmpty else { return }
        let result = try await ProcessRunner.run(
            executable: executablePath,
            args: [
                "api", "--method", "POST",
                "repos/\(owner)/\(repo)/pulls/\(number)/requested_reviewers",
                "-f", "reviewers[]=\(login)",
            ]
        )
        guard result.succeeded else {
            throw GHError.execFailed(
                stderr: result.stderrString ?? "",
                exitCode: result.exitCode
            )
        }
    }

    /// One inline review comment, anchored to a span in the PR's diff
    /// against the PR's head commit. `line` is the last line of the span
    /// (the GitHub API places the comment there); `startLine` is set for
    /// multi-line ranges, omitted for single-line.
    struct InlineComment: Sendable, Hashable {
        let path: String
        let line: Int
        let startLine: Int?
        let body: String
    }

    /// Submit a review with inline (line-anchored) comments in a single
    /// API call. Uses `POST /repos/{o}/{r}/pulls/{n}/reviews` because
    /// `gh pr review` doesn't expose `comments[]`.
    ///
    /// `event`: `"APPROVE"`, `"REQUEST_CHANGES"`, or `"COMMENT"` (neutral).
    /// `body`: review body — required for REQUEST_CHANGES and COMMENT,
    /// optional for APPROVE. `comments`: zero or more inline comments;
    /// each anchors against the PR's current head SHA (the API defaults
    /// `commit_id` to head when omitted).
    ///
    /// GitHub rejects inline comments whose `line` isn't part of the
    /// PR's diff. Caller is responsible for filtering out annotations
    /// against unchanged regions before passing them in.
    func postReviewWithComments(
        owner: String,
        repo: String,
        number: Int,
        event: String,
        body: String,
        comments: [InlineComment]
    ) async throws {
        struct CommentPayload: Encodable {
            let path: String
            let body: String
            let line: Int
            // GitHub's create-review endpoint takes `start_line` only
            // when the range spans more than one line; encoding it
            // unconditionally with the same value as `line` triggers
            // 422 "start_line must be less than line".
            let start_line: Int?
        }
        struct ReviewPayload: Encodable {
            let event: String
            let body: String?
            let comments: [CommentPayload]
        }

        let payload = ReviewPayload(
            event: event,
            body: body.isEmpty ? nil : body,
            comments: comments.map {
                CommentPayload(
                    path: $0.path,
                    body: $0.body,
                    line: $0.line,
                    start_line: ($0.startLine != nil && $0.startLine! < $0.line) ? $0.startLine : nil
                )
            }
        )
        let data = try JSONEncoder().encode(payload)

        // gh api --input <file> reads the JSON body from disk so we
        // don't have to thread stdin through ProcessRunner.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("prbar-review-\(UUID().uuidString).json")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = try await ProcessRunner.run(
            executable: executablePath,
            args: [
                "api",
                "--method", "POST",
                "repos/\(owner)/\(repo)/pulls/\(number)/reviews",
                "--input", tmp.path,
            ]
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
        deleteBranch: Bool = false,
        auto: Bool = false
    ) async throws {
        var args: [String] = [
            "pr", "merge", "\(number)",
            "--repo", "\(owner)/\(repo)",
            method.ghFlag,
        ]
        // `--auto` tells GitHub to merge automatically once required checks
        // and reviews pass, instead of failing immediately when the PR isn't
        // yet mergeable. The method flag still applies — it picks the
        // strategy the queued merge will use.
        if auto {
            args.append("--auto")
        }
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

    /// Cancel a pending auto-merge request. No method flag — `--disable-auto`
    /// only clears the queued merge; it doesn't merge anything.
    func disableAutoMerge(
        owner: String,
        repo: String,
        number: Int
    ) async throws {
        let result = try await ProcessRunner.run(
            executable: executablePath,
            args: [
                "pr", "merge", "\(number)",
                "--repo", "\(owner)/\(repo)",
                "--disable-auto",
            ]
        )
        guard result.succeeded else {
            throw GHError.execFailed(
                stderr: result.stderrString ?? "",
                exitCode: result.exitCode
            )
        }
    }
}
