import Foundation

/// `prbar-review mcp`: a Model Context Protocol server over stdio, started
/// by a coding agent (`claude mcp add prbar -- prbar-review mcp`). Every
/// tool is one or more calls to the running PRBar server; this process holds
/// no state of its own and never talks to GitHub.
///
/// It identifies itself to the server as an agent, so the server, not this
/// adapter, applies the `agents:` policy from `prbar.yaml`.
enum MCPCommand {
    static let usage = """
    usage: prbar-review mcp

    Serves PRBar to a coding agent over the Model Context Protocol (stdio).
    Register it once, e.g. for Claude Code:

      claude mcp add prbar -- prbar-review mcp

    Needs a running PRBar (the app, or `prbar-review serve`). What agents may
    do is set by the `agents:` block of prbar.yaml.

    """

    static func run(socketURL: URL = ServerLocation.socketURL()) async -> Int32 {
        let session = MCPSession(socketURL: socketURL)
        for await line in stdinLines() {
            if let reply = await session.handle(line) {
                FileHandle.standardOutput.write(reply + Data("\n".utf8))
            }
        }
        await session.close()
        return 0
    }

    /// Lines from stdin, read on a thread of its own so the cooperative
    /// pool never blocks on the agent.
    private static func stdinLines() -> AsyncStream<Data> {
        let (stream, sink) = AsyncStream<Data>.makeStream()
        let thread = Thread {
            while let line = readLine(strippingNewline: true) {
                if !line.isEmpty { sink.yield(Data(line.utf8)) }
            }
            sink.finish()
        }
        thread.name = "prbar-mcp-stdin"
        thread.start()
        return stream
    }
}

/// One MCP conversation. `handle` takes a request line and returns the
/// reply line (nil for notifications), so it is testable without stdio.
actor MCPSession {
    /// Newest first. The reply echoes the client's version when it is in
    /// here, else offers the newest.
    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    private let socketURL: URL
    private var clientName = "mcp"
    private var client: APIClient?

    init(socketURL: URL) {
        self.socketURL = socketURL
    }

    func close() {
        client?.close()
        client = nil
    }

    func handle(_ line: Data) async -> Data? {
        guard let header = try? RPCLine.decode(MCPHeader.self, from: line) else {
            return Self.failure(nil, RPCError(code: RPCError.parseError, message: "not a JSON-RPC message"))
        }
        guard let method = header.method else { return nil }
        // Notifications (initialized, cancelled, ...) get no reply.
        guard let id = header.id else { return nil }

        switch method {
        case "initialize":
            let params = (try? RPCLine.decode(MCPRequest<InitializeParams>.self, from: line))?.params
            if let name = params?.clientInfo?.name { clientName = "mcp:\(name)" }
            let requested = params?.protocolVersion ?? ""
            let version = Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0]
            return Self.success(id, InitializeResult(
                protocolVersion: version,
                serverInfo: .init(name: "prbar", version: PRBarBuild.version)))
        case "ping":
            return Self.success(id, APIEmpty())
        case "tools/list":
            return Self.success(id, ToolList(tools: MCPTools.all))
        case "tools/call":
            guard let name = (try? RPCLine.decode(MCPRequest<ToolCallName>.self, from: line))?.params?.name else {
                return Self.failure(id, RPCError(code: RPCError.invalidParams, message: "tools/call needs a tool name"))
            }
            guard MCPTools.all.contains(where: { $0.name == name }) else {
                return Self.failure(id, RPCError(code: RPCError.invalidParams, message: "unknown tool \(name)"))
            }
            return Self.success(id, await callTool(name, line))
        default:
            return Self.failure(id, RPCError(code: RPCError.methodNotFound, message: "unknown method \(method)"))
        }
    }

    // MARK: - Tools

    private func callTool(_ name: String, _ line: Data) async -> ToolResult {
        do {
            switch name {
            case "status":
                let status = try await api { try await $0.call(.status, as: ServerStatus.self) }
                return ToolResult(text: ClientCommand.describe(status, now: Date()))
            case "list_inbox":
                let args = try arguments(InboxArgs.self, line)
                return ToolResult(text: try await listInbox(filter: args?.filter ?? .all))
            case "get_review":
                guard let ref = try Self.reference(arguments(PRArgs.self, line)?.pr) else {
                    return ToolResult(error: "pr is required: a PR URL or owner/repo#number")
                }
                let result = try await api { try await $0.call(.review, ref, as: ReviewResult.self) }
                return ToolResult(text: MCPText.review(result))
            case "run_review":
                let args = try arguments(RunReviewArgs.self, line)
                guard let ref = try Self.reference(args?.pr) else {
                    return ToolResult(error: "pr is required: a PR URL or owner/repo#number")
                }
                let params = RunReviewParams(pr: ref, force: args?.force)
                let result = try await api { try await $0.call(.runReview, params, as: ReviewResult.self) }
                return ToolResult(text: MCPText.started(result, forced: args?.force ?? false))
            case "get_history":
                let args = try arguments(HistoryArgs.self, line)
                let limit = HistoryParams(limit: min(max(args?.limit ?? 20, 1), 200))
                if args?.kind == .actions {
                    let records = try await api { try await $0.call(.historyActions, limit, as: [ActionRecord].self) }
                    return ToolResult(text: records.isEmpty ? "No actions recorded." : records.map(ClientCommand.describe).joined(separator: "\n"))
                }
                let records = try await api { try await $0.call(.historyReviews, limit, as: [ReviewRecord].self) }
                return ToolResult(text: records.isEmpty ? "No reviews recorded." : records.map(ClientCommand.describe).joined(separator: "\n"))
            default:
                return ToolResult(error: "unknown tool \(name)")
            }
        } catch let error as DecodingError {
            return ToolResult(error: "invalid arguments for \(name): \(error)")
        } catch {
            return ToolResult(error: error.localizedDescription)
        }
    }

    private func listInbox(filter: InboxArgs.Filter) async throws -> String {
        let prs = try await api { try await $0.call(.inbox, as: [InboxPR].self) }
        let shown = prs.filter {
            switch filter {
            case .all: return $0.role != .other
            case .reviewRequested: return $0.role == .reviewRequested || $0.role == .both
            case .mine: return $0.role == .authored || $0.role == .both
            }
        }
        guard !shown.isEmpty else { return "No pull requests." }
        var lines: [String] = []
        for pr in shown {
            let state = try await api {
                try await $0.call(.review, PRReference(nodeId: pr.nodeId), as: ReviewResult.self)
            }.review
            lines.append(MCPText.inboxLine(pr, state))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Plumbing

    /// Runs `body` against the server, connecting on first use and once
    /// more if the server went away in between (a restart mid-session
    /// costs one retry, not a dead tool).
    private func api<T: Sendable>(_ body: (APIClient) async throws -> T) async throws -> T {
        do {
            return try await body(connected())
        } catch APIClientError.disconnected {
            close()
            return try await body(connected())
        }
    }

    private func connected() async throws -> APIClient {
        if let client { return client }
        let fresh = try await ServerConnection.connect(socketURL: socketURL, client: clientName, agent: true).client
        client = fresh
        return fresh
    }

    private func arguments<T: Decodable & Sendable>(_: T.Type, _ line: Data) throws -> T? {
        try RPCLine.decode(MCPRequest<ToolCallArguments<T>>.self, from: line).params?.arguments
    }

    static func reference(_ text: String?) throws -> PRReference? {
        guard let text, !text.isEmpty else { return nil }
        guard let target = Invocation.parseTarget(text) else {
            throw RPCError(code: RPCError.invalidParams, message: "not a PR: \(text) (use a PR URL or owner/repo#number)")
        }
        return PRReference(owner: target.owner, repo: target.repo, number: target.number)
    }

    private static func success<R: Encodable>(_ id: MCPID, _ result: R) -> Data? {
        try? RPCLine.encode(MCPSuccess(id: id, result: result))
    }

    private static func failure(_ id: MCPID?, _ error: RPCError) -> Data? {
        try? RPCLine.encode(MCPFailure(id: id, error: error))
    }
}

// MARK: - Tool catalogue

enum MCPTools {
    static let all: [MCPTool] = [
        MCPTool(
            name: "status",
            description: "Whether PRBar is running and healthy: when it last polled GitHub, how many reviews are queued or running, and any config problems.",
            inputSchema: .init(properties: [:]),
            annotations: .init(readOnlyHint: true)),
        MCPTool(
            name: "list_inbox",
            description: "Pull requests PRBar is tracking for the user, with the state of PRBar's AI review of each.",
            inputSchema: .init(properties: [
                "filter": .init(
                    type: "string",
                    description: "review_requested: waiting on the user's review. mine: authored by the user. all (default): both.",
                    enumValues: ["all", "review_requested", "mine"]),
            ]),
            annotations: .init(readOnlyHint: true)),
        MCPTool(
            name: "get_review",
            description: "PRBar's AI review of a pull request: verdict, summary and every finding with its file and lines. Use it on the PR you are working on, fix the findings, push, then call run_review to check again.",
            inputSchema: .init(
                properties: ["pr": .init(type: "string", description: "PR URL or owner/repo#number")],
                required: ["pr"]),
            annotations: .init(readOnlyHint: true)),
        MCPTool(
            name: "run_review",
            description: "Start PRBar's AI review of a pull request at its current head commit. Returns at once; a review usually takes a few minutes, then get_review shows it. Costs money: only call it after pushing changes, not to poll.",
            inputSchema: .init(
                properties: [
                    "pr": .init(type: "string", description: "PR URL or owner/repo#number"),
                    "force": .init(
                        type: "boolean",
                        description: "Review again even when this commit was already reviewed, or a repo rule would skip it."),
                ],
                required: ["pr"]),
            annotations: .init(readOnlyHint: false, idempotentHint: true)),
        MCPTool(
            name: "get_history",
            description: "Recent history, newest first: AI reviews PRBar ran (kind reviews, default) or GitHub actions it took (kind actions).",
            inputSchema: .init(properties: [
                "kind": .init(type: "string", description: "reviews (default) or actions", enumValues: ["reviews", "actions"]),
                "limit": .init(type: "integer", description: "How many entries, 1-200 (default 20)"),
            ]),
            annotations: .init(readOnlyHint: true)),
    ]
}

/// What the tools say, kept apart from the plumbing so it can be read and
/// tested as text.
enum MCPText {
    static func inboxLine(_ pr: InboxPR, _ state: ReviewState?) -> String {
        let role: String
        switch pr.role {
        case .reviewRequested: role = "review requested"
        case .authored: role = "yours"
        case .both: role = "yours, review requested"
        case .other: role = "involved"
        }
        return "\(pr.nameWithOwner)#\(pr.number) [\(role)\(pr.isDraft ? ", draft" : "")] \(pr.title)\n  \(pr.url.absoluteString)\n  AI review: \(stateLine(state, headSha: pr.headSha))"
    }

    static func stateLine(_ state: ReviewState?, headSha: String) -> String {
        guard let state else { return "none" }
        let stale = state.headSha != headSha ? " (of an older commit)" : ""
        switch state.status {
        case .queued: return "queued\(stale)"
        case .running: return "running\(stale)"
        case .completed(let review):
            return "\(review.verdict.displayName), \(findingCount(review.annotations))\(stale)"
        case .failed(let message): return "failed: \(message)\(stale)"
        case .skipped(let reason): return "skipped, \(reason.short)\(stale)"
        }
    }

    static func review(_ result: ReviewResult) -> String {
        let pr = result.pr
        var out = "\(pr.nameWithOwner)#\(pr.number): \(pr.title)\n\(pr.url.absoluteString)\n\n"
        guard let state = result.review else {
            return out + "PRBar has not reviewed this PR. Call run_review to start one."
        }
        if state.headSha != pr.headSha {
            out += "Note: this review is of \(state.headSha.prefix(7)); the PR is now at \(pr.headSha.prefix(7)).\n\n"
        }
        switch state.status {
        case .queued:
            return out + "A review is queued. Check again in a few minutes."
        case .running:
            return out + "A review is running. Check again in a few minutes."
        case .failed(let message):
            return out + "The last review failed: \(message)"
        case .skipped(let reason):
            return out + "Not reviewed: \(reason.detail) run_review with force true reviews it anyway."
        case .completed(let review):
            out += "Review of \(state.headSha.prefix(7)) by \(state.providerId.rawValue): \(review.verdict.displayName), confidence \(String(format: "%.2f", review.confidence)), \(String(format: "$%.2f", review.costUsd))\n\n"
            out += review.summaryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            let findings = review.annotations.sorted { ($0.severity, $1.path) > ($1.severity, $0.path) }
            if findings.isEmpty { return out + "\nNo findings." }
            out += "\nFindings (\(findings.count)):\n"
            for finding in findings {
                let lines = finding.lineStart == finding.lineEnd ? "\(finding.lineStart)" : "\(finding.lineStart)-\(finding.lineEnd)"
                out += "\n- [\(finding.severity.rawValue)] \(finding.path):\(lines) \(finding.displayTitle)\n"
                out += finding.body.split(separator: "\n", omittingEmptySubsequences: false).map { "  \($0)" }.joined(separator: "\n") + "\n"
            }
            return out
        }
    }

    static func started(_ result: ReviewResult, forced: Bool) -> String {
        let pr = result.pr
        let name = "\(pr.nameWithOwner)#\(pr.number)"
        guard let state = result.review, state.headSha == pr.headSha else {
            return "\(name) was not queued for review. Call status to check PRBar."
        }
        switch state.status {
        case .queued, .running:
            return "Review of \(name) at \(pr.headSha.prefix(7)) is \(state.status.isInFlight && !forced ? "queued or running" : "queued"). It usually takes a few minutes; call get_review to see the result."
        case .completed:
            return "\(name) was already reviewed at \(pr.headSha.prefix(7)); pass force true to review it again.\n\n" + review(result)
        case .skipped(let reason):
            return "\(name) was not reviewed: \(reason.detail) Pass force true to review it anyway."
        case .failed(let message):
            return "The review of \(name) failed: \(message)"
        }
    }

    private static func findingCount(_ annotations: [DiffAnnotation]) -> String {
        guard !annotations.isEmpty else { return "no findings" }
        let bySeverity = Dictionary(grouping: annotations, by: \.severity)
        let parts = AnnotationSeverity.allCases.reversed().compactMap { severity -> String? in
            guard let n = bySeverity[severity]?.count else { return nil }
            return "\(n) \(severity.rawValue)"
        }
        return "\(annotations.count) finding\(annotations.count == 1 ? "" : "s") (\(parts.joined(separator: ", ")))"
    }
}

// MARK: - Wire types

/// MCP request ids may be numbers or strings, and the reply must echo
/// whichever was sent.
enum MCPID: Codable, Sendable, Hashable {
    case int(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self) {
            self = .int(n)
        } else {
            self = .string(try c.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        }
    }
}

struct MCPHeader: Decodable {
    var id: MCPID?
    var method: String?
}

struct MCPRequest<Params: Decodable & Sendable>: Decodable {
    var params: Params?
}

struct MCPSuccess<Result: Encodable>: Encodable {
    var jsonrpc = "2.0"
    var id: MCPID
    var result: Result
}

struct MCPFailure: Encodable {
    var jsonrpc = "2.0"
    var id: MCPID?
    var error: RPCError

    // JSON-RPC wants `"id": null` when the request's id couldn't be read.
    enum CodingKeys: String, CodingKey { case jsonrpc, id, error }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jsonrpc, forKey: .jsonrpc)
        if let id { try c.encode(id, forKey: .id) } else { try c.encodeNil(forKey: .id) }
        try c.encode(error, forKey: .error)
    }
}

struct InitializeParams: Decodable, Sendable {
    struct ClientInfo: Decodable, Sendable {
        var name: String?
    }
    var protocolVersion: String?
    var clientInfo: ClientInfo?
}

struct InitializeResult: Encodable {
    struct Capabilities: Encodable {
        struct Tools: Encodable { var listChanged = false }
        var tools = Tools()
    }
    struct ServerInfo: Encodable {
        var name: String
        var version: String
    }
    var protocolVersion: String
    var capabilities = Capabilities()
    var serverInfo: ServerInfo
    var instructions = "PRBar reviews the user's GitHub pull requests with an AI reviewer and tracks their review inbox. On a PR you are working on: get_review to read PRBar's findings, fix them, push, then run_review to check again."
}

struct ToolList: Encodable {
    var tools: [MCPTool]
}

struct MCPTool: Encodable, Sendable {
    struct Schema: Encodable, Sendable {
        var type = "object"
        var properties: [String: Property]
        var required: [String]?

        init(properties: [String: Property], required: [String]? = nil) {
            self.properties = properties
            self.required = required
        }
    }

    struct Property: Encodable, Sendable {
        var type: String
        var description: String
        var enumValues: [String]?

        enum CodingKeys: String, CodingKey {
            case type, description
            case enumValues = "enum"
        }
    }

    struct Annotations: Encodable, Sendable {
        var readOnlyHint: Bool?
        var idempotentHint: Bool?
    }

    var name: String
    var description: String
    var inputSchema: Schema
    var annotations: Annotations?
}

struct ToolCallName: Decodable, Sendable {
    var name: String
}

struct ToolCallArguments<Arguments: Decodable & Sendable>: Decodable, Sendable {
    var arguments: Arguments?
}

struct ToolResult: Encodable, Sendable {
    struct Content: Encodable, Sendable {
        var type = "text"
        var text: String
    }

    var content: [Content]
    var isError: Bool?

    init(text: String) {
        content = [Content(text: text)]
    }

    init(error: String) {
        content = [Content(text: error)]
        isError = true
    }
}

struct InboxArgs: Decodable, Sendable {
    enum Filter: String, Decodable, Sendable {
        case all
        case reviewRequested = "review_requested"
        case mine
    }
    var filter: Filter?
}

struct PRArgs: Decodable, Sendable {
    var pr: String?
}

struct RunReviewArgs: Decodable, Sendable {
    var pr: String?
    var force: Bool?
}

struct HistoryArgs: Decodable, Sendable {
    enum Kind: String, Decodable, Sendable {
        case reviews, actions
    }
    var kind: Kind?
    var limit: Int?
}
