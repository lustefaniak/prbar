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
        let output = NSLock()
        // Each request on its own task: a `watch` waits for minutes, and
        // the agent may call other tools (or ping) meanwhile.
        await withTaskGroup(of: Void.self) { group in
            for await line in stdinLines() {
                group.addTask {
                    guard let reply = await session.handle(line) else { return }
                    output.withLock { FileHandle.standardOutput.write(reply + Data("\n".utf8)) }
                }
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
            guard let tool = MCPTools.all.first(where: { $0.name == name }) else {
                return Self.failure(id, RPCError(code: RPCError.invalidParams, message: "unknown tool \(name)"))
            }
            if let problem = Self.argumentProblem(tool, line) {
                return Self.success(id, ToolResult(error: problem))
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
                return ToolResult(text: MCPText.status(status, now: Date()))
            case "list_inbox":
                let args = try arguments(InboxArgs.self, line)
                return ToolResult(text: try await listInbox(filter: args?.filter ?? .all))
            case "get_review":
                let args = try arguments(GetReviewArgs.self, line)
                if let problem = Self.onePRorPath(args?.pr, args?.path) { return ToolResult(error: problem) }
                if let path = args?.path {
                    return try await getLocalReview(path, full: args?.full ?? false)
                }
                guard let ref = try Self.reference(args?.pr) else {
                    return ToolResult(error: "pr is required: a PR URL or owner/repo#number")
                }
                return try await getReview(ref, full: args?.full ?? false)
            case "run_review":
                let args = try arguments(RunReviewArgs.self, line)
                if let problem = Self.onePRorPath(args?.pr, args?.path) { return ToolResult(error: problem) }
                if let path = args?.path {
                    let params = LocalReviewParams(path: path, base: args?.base, force: args?.force)
                    let result = try await api { try await $0.call(.reviewLocal, params, as: ReviewResult.self) }
                    if let ignored = result.ignored { return ToolResult(text: "Not reviewed: \(ignored).") }
                    return ToolResult(text: MCPText.started(result, forced: args?.force ?? false))
                }
                if args?.base != nil { return ToolResult(error: "base goes with path, not pr: a PR's base is its target branch.") }
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
            case "watch":
                let args = try arguments(WatchArgs.self, line)
                if args?.pr != nil, args?.path != nil { return ToolResult(error: "pass pr or path, not both.") }
                var subject: String?
                if let ref = try Self.reference(args?.pr) { subject = MCPText.name(ref) }
                if let path = args?.path { subject = try await LocalChanges.root(of: path) }
                let timeout = min(max(args?.timeoutSeconds ?? 60, 1), MCPTools.watchMaxSeconds)
                return try await watch(since: args?.since, subject: subject, timeout: TimeInterval(timeout))
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
        var states: [String: ReviewState] = [:]
        for pr in shown {
            states[pr.nodeId] = try await api {
                try await $0.call(.review, PRReference(nodeId: pr.nodeId), as: ReviewResult.self)
            }.review
        }
        return MCPText.inbox(shown, states: states, filter: filter)
    }

    /// PRBar's review state for an inbox PR, else the newest review of it
    /// in the history: a PR leaves the inbox once it's merged or reviewed.
    private func getReview(_ ref: PRReference, full: Bool) async throws -> ToolResult {
        do {
            let result = try await api { try await $0.call(.review, ref, as: ReviewResult.self) }
            return ToolResult(text: MCPText.review(result, full: full))
        } catch let error as RPCError where error.code == RPCError.notFound {
            let params = HistoryParams(limit: 1, pr: ref)
            let records = try await api { try await $0.call(.historyReviews, params, as: [ReviewRecord].self) }
            guard let record = records.first(where: { APIServer.matches($0.owner, $0.repo, $0.prNumber, ref) }) else {
                return ToolResult(text: "PRBar isn't tracking \(MCPText.name(ref)) and has no review of it in its history. It tracks PRs where the user is a requested reviewer or the author.")
            }
            var review: AggregatedReview?
            if record.hasReview {
                review = try await api {
                    try await $0.call(.fullReview, FullReviewParams(id: record.id), as: FullReviewResult.self)
                }.review
            }
            return ToolResult(text: MCPText.historic(record, review: review, full: full))
        }
    }

    private func getLocalReview(_ path: String, full: Bool) async throws -> ToolResult {
        do {
            let result = try await api { try await $0.call(.review, PRReference(path: path), as: ReviewResult.self) }
            return ToolResult(text: MCPText.review(result, full: full))
        } catch let error as RPCError where error.code == RPCError.notFound {
            return ToolResult(text: "PRBar hasn't reviewed the changes in \(path) since it started. run_review with path \(path) starts a review.")
        }
    }

    static func onePRorPath(_ pr: String?, _ path: String?) -> String? {
        switch (pr, path) {
        case (nil, nil): return "pass pr (a PR URL or owner/repo#number) or path (a local checkout)."
        case (.some, .some): return "pass pr or path, not both."
        default: return nil
        }
    }

    // MARK: - Watching

    /// Events from the server, numbered in arrival order for `watch`
    /// cursors. Filled only once an agent first watches.
    private var events: [(seq: Int, event: APIEvent)] = []
    private var lastSeq = 0
    private var subscribed: ObjectIdentifier?
    static let eventBufferLimit = 1000

    private func watch(since: Int?, subject: String?, timeout: TimeInterval) async throws -> ToolResult {
        try await api { try await self.subscribe($0) }
        let cursor = since ?? lastSeq
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let found = events.filter { $0.seq > cursor && Self.concerns($0.event, subject) }
            if !found.isEmpty || Date() >= deadline || Task.isCancelled || subscribed == nil {
                let dropped = since.map { $0 < (events.first?.seq ?? lastSeq + 1) - 1 } ?? false
                return ToolResult(text: MCPText.watched(
                    found.map(\.event), cursor: lastSeq, dropped: dropped,
                    serverGone: subscribed == nil, subject: subject, waited: timeout))
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Subscribes `client` to events, once per connection.
    private func subscribe(_ client: APIClient) async throws {
        let key = ObjectIdentifier(client)
        guard subscribed != key else { return }
        _ = try await client.call(.subscribe, SubscribeParams(), as: SubscribeResult.self)
        subscribed = key
        Task { [weak self] in
            for await event in client.events { await self?.record(event) }
            await self?.lost(key)
        }
    }

    private var lastInboxCount: Int?

    private func record(_ event: APIEvent) {
        // The server sends one after every poll; only a change is news.
        if event.kind == .inboxChanged {
            guard event.count != lastInboxCount else { return }
            lastInboxCount = event.count
        }
        lastSeq += 1
        events.append((lastSeq, event))
        if events.count > Self.eventBufferLimit { events.removeFirst(events.count - Self.eventBufferLimit) }
    }

    private func lost(_ key: ObjectIdentifier) {
        if subscribed == key { subscribed = nil }
    }

    /// `subject` is `owner/repo#number`, or a checkout's root for a local review.
    private static func concerns(_ event: APIEvent, _ subject: String?) -> Bool {
        guard let subject else { return true }
        guard let name = event.pr else { return false }
        return name.caseInsensitiveCompare(subject) == .orderedSame
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

    /// Why `line`'s arguments don't fit `tool`'s schema, or nil. Checked
    /// before decoding so the agent hears which argument is wrong and what
    /// it may be, not a Swift decoding error, and so a misspelt argument
    /// is refused rather than ignored.
    static func argumentProblem(_ tool: MCPTool, _ line: Data) -> String? {
        let given: [String: MCPArgumentValue]
        do {
            given = try RPCLine.decode(MCPRequest<ToolCallArguments<[String: MCPArgumentValue]>>.self, from: line).params?.arguments ?? [:]
        } catch {
            return "arguments for \(tool.name) must be a JSON object"
        }
        let known = tool.inputSchema.properties
        for key in given.keys.sorted() where known[key] == nil {
            let takes = known.keys.sorted()
            return takes.isEmpty
                ? "\(tool.name) takes no arguments; got \(key)."
                : "\(tool.name) has no argument \(key). It takes: \(takes.joined(separator: ", "))."
        }
        for (key, value) in given.sorted(by: { $0.key < $1.key }) {
            guard let property = known[key], value != .null else { continue }
            switch (property.type, value) {
            case ("string", .string(let text)):
                if let allowed = property.enumValues, !allowed.contains(text) {
                    return "\(key) must be one of \(allowed.joined(separator: ", ")); got \"\(text)\"."
                }
            case ("integer", .integer), ("boolean", .bool):
                continue
            default:
                let article = property.type == "integer" ? "an" : "a"
                return "\(key) must be \(article) \(property.type)."
            }
        }
        return nil
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
    static let watchMaxSeconds = 300

    static let all: [MCPTool] = [
        MCPTool(
            name: "status",
            description: "Whether PRBar is running and healthy: when it last polled GitHub, how many reviews are queued or running, config problems, and what coding agents may do (agents: read, review, post, merge).",
            inputSchema: .init(properties: [:]),
            annotations: .init(readOnlyHint: true)),
        MCPTool(
            name: "list_inbox",
            description: "Pull requests PRBar is tracking for the user, one line each with the state of PRBar's AI review.",
            inputSchema: .init(properties: [
                "filter": .init(
                    type: "string",
                    description: "review_requested: waiting on the user's review. mine: authored by the user. all (default): both.",
                    enumValues: ["all", "review_requested", "mine"]),
            ]),
            annotations: .init(readOnlyHint: true)),
        MCPTool(
            name: "get_review",
            description: "PRBar's AI review of a pull request, or of local changes reviewed with run_review and a path: verdict, summary and every finding with its file and lines. Works for PRs PRBar no longer tracks too, from its history. Use it on what you are working on, fix the findings, then call run_review to check again.",
            inputSchema: .init(
                properties: [
                    "pr": .init(type: "string", description: "PR URL or owner/repo#number"),
                    "path": .init(type: "string", description: "Instead of pr: a directory in a local checkout reviewed with run_review."),
                    "full": .init(type: "boolean", description: "Show long summaries and findings whole instead of cut short."),
                ]),
            annotations: .init(readOnlyHint: true)),
        MCPTool(
            name: "run_review",
            description: "Start PRBar's AI review of a pull request at its current head commit, or, with path, of the uncommitted and unpushed work in a local checkout against where its branch forked (nothing is posted for that; the repo's review rules still apply). Returns at once; a review usually takes a few minutes. Wait with watch (pass the same pr or path), then read it with get_review. Costs money: only call it once there is something new to review, not to poll.",
            inputSchema: .init(
                properties: [
                    "pr": .init(type: "string", description: "PR URL or owner/repo#number"),
                    "path": .init(type: "string", description: "Instead of pr: a directory in a local git checkout, e.g. the one you are working in."),
                    "base": .init(type: "string", description: "With path: the branch or commit to compare with (default: where the branch forked from origin's default branch)."),
                    "force": .init(
                        type: "boolean",
                        description: "Review again even when these exact changes were already reviewed, or a repo rule would skip it."),
                ]),
            annotations: .init(readOnlyHint: false, idempotentHint: true)),
        MCPTool(
            name: "get_history",
            description: "Recent history, newest first: AI reviews PRBar ran (kind reviews, default) or GitHub actions it took (kind actions).",
            inputSchema: .init(properties: [
                "kind": .init(type: "string", description: "reviews (default) or actions", enumValues: ["reviews", "actions"]),
                "limit": .init(type: "integer", description: "How many entries, 1-200 (default 20)"),
            ]),
            annotations: .init(readOnlyHint: true)),
        MCPTool(
            name: "watch",
            description: "Wait for something to happen in PRBar: a review finishing, a GitHub action completing, the inbox or prbar.yaml changing. Returns as soon as there is news, or after timeout_seconds with nothing. Every reply ends with a cursor; pass it as since next time so nothing is missed between calls.",
            inputSchema: .init(properties: [
                "pr": .init(type: "string", description: "Only news about this PR (URL or owner/repo#number), e.g. the one you just called run_review on."),
                "path": .init(type: "string", description: "Only news about the local review of this checkout."),
                "since": .init(type: "integer", description: "The cursor from the previous watch. Omit to wait for what happens from now on."),
                "timeout_seconds": .init(type: "integer", description: "How long to wait, 1-\(watchMaxSeconds) (default 60)."),
            ]),
            annotations: .init(readOnlyHint: true)),
    ]
}

/// What the tools say, kept apart from the plumbing so it can be read and
/// tested as text.
enum MCPText {
    /// Past these, text is cut short unless the agent asks for `full`.
    static let summaryLimit = 2000
    static let findingLimit = 800

    static func name(_ ref: PRReference) -> String {
        "\(ref.owner ?? "?")/\(ref.repo ?? "?")#\(ref.number.map(String.init) ?? "?")"
    }

    static func status(_ status: ServerStatus, now: Date) -> String {
        ClientCommand.describe(status, now: now)
            + "\n\nNext: list_inbox for the PRs, get_review for one PR's review, watch to wait for changes."
    }

    static func inbox(_ prs: [InboxPR], states: [String: ReviewState], filter: InboxArgs.Filter) -> String {
        guard !prs.isEmpty else {
            switch filter {
            case .all: return "No pull requests: nothing awaits the user's review and the user has no open PRs."
            case .reviewRequested: return "No pull requests await the user's review."
            case .mine: return "The user has no open pull requests."
            }
        }
        let requested = prs.filter { $0.role == .reviewRequested || $0.role == .both }.count
        let mine = prs.filter { $0.role == .authored || $0.role == .both }.count
        var lines = ["\(prs.count) pull request\(prs.count == 1 ? "" : "s"): \(requested) awaiting the user's review, \(mine) authored by the user."]
        lines += prs.map { inboxLine($0, states[$0.nodeId]) }
        lines.append("\nNext: get_review with one of these for PRBar's findings.")
        return lines.joined(separator: "\n")
    }

    static func inboxLine(_ pr: InboxPR, _ state: ReviewState?) -> String {
        let role: String
        switch pr.role {
        case .reviewRequested: role = "review requested"
        case .authored: role = "authored"
        case .both: role = "authored, review requested"
        case .other: role = "involved"
        }
        return "\(pr.nameWithOwner)#\(pr.number) [\(role)\(pr.isDraft ? ", draft" : "")] \(pr.title) · AI review: \(stateLine(state, headSha: pr.headSha))"
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

    /// How to name `pr` as a tool argument: `pr o/r#1`, or `path <root>`.
    static func argument(_ pr: InboxPR) -> String {
        pr.local.map { "path \($0.root)" } ?? "pr \(pr.nameWithOwner)#\(pr.number)"
    }

    static func review(_ result: ReviewResult, full: Bool = false) -> String {
        let pr = result.pr
        let name = "\(pr.nameWithOwner)#\(pr.number)"
        var out: String
        if let local = pr.local {
            out = "Local changes in \(local.root) on \(local.branch), against \(local.baseRef) (\(local.changedFiles) files, +\(local.additions) -\(local.deletions))\n\n"
        } else {
            out = "\(name): \(pr.title)\n\(pr.url.absoluteString)\n\n"
        }
        guard let state = result.review else {
            return out + "PRBar has not reviewed this. Call run_review with \(argument(pr)) to start one."
        }
        if state.headSha != pr.headSha {
            out += "Note: this review is of \(state.headSha.prefix(7)); the PR is now at \(pr.headSha.prefix(7)).\n\n"
        }
        switch state.status {
        case .queued:
            return out + "A review is queued. watch with \(argument(pr)) waits for it to finish."
        case .running:
            return out + "A review is running. watch with \(argument(pr)) waits for it to finish."
        case .failed(let message):
            return out + "The last review failed: \(message)"
        case .skipped(let reason):
            return out + "Not reviewed: \(reason.detail) run_review with force true reviews it anyway."
        case .completed(let review):
            out += "Review of \(state.headSha.prefix(7)) by \(state.providerId.rawValue): "
            return out + completed(review, full: full)
                + (pr.local == nil
                    ? "\nNext: fix what applies, push, then run_review to check the new commit."
                    : "\nNext: fix what applies, then run_review with \(argument(pr)) to check again.")
        }
    }

    /// The last review of a PR PRBar no longer tracks, from its history.
    static func historic(_ record: ReviewRecord, review: AggregatedReview?, full: Bool) -> String {
        var out = "\(record.nameWithOwner)#\(record.prNumber): \(record.prTitle)\n"
        out += "PRBar no longer tracks this PR (merged, closed, or the user's review is done). Its last review, from \(ISO8601DateFormatter().string(from: record.completedAt)):\n\n"
        if let review {
            return out + "Review of \(record.headSha.prefix(7)) by \(record.providerId.rawValue): " + completed(review, full: full)
        }
        if let error = record.errorMessage {
            return out + "That review failed: \(error)"
        }
        return out + "Verdict: \(record.verdict?.displayName ?? "none"). The full review wasn't kept."
    }

    static func completed(_ review: AggregatedReview, full: Bool) -> String {
        var cut = false
        func limited(_ text: String, _ limit: Int) -> String {
            guard !full, text.count > limit else { return text }
            cut = true
            return text.prefix(limit).trimmingCharacters(in: .whitespacesAndNewlines) + " [cut short]"
        }
        var out = "\(review.verdict.displayName), confidence \(String(format: "%.2f", review.confidence)), \(String(format: "$%.2f", review.costUsd))\n\n"
        out += limited(review.summaryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines), summaryLimit) + "\n"
        let findings = review.annotations.sorted { ($0.severity, $1.path) > ($1.severity, $0.path) }
        if findings.isEmpty {
            out += "\nNo findings.\n"
        } else {
            out += "\nFindings (\(findings.count)):\n"
            for finding in findings {
                let lines = finding.lineStart == finding.lineEnd ? "\(finding.lineStart)" : "\(finding.lineStart)-\(finding.lineEnd)"
                // Without a title the headline would be the body's first
                // sentence, said twice.
                let title = finding.title.map(DiffAnnotation.normalizeTitle).flatMap { $0.isEmpty ? nil : " " + $0 } ?? ""
                out += "\n- [\(finding.severity.rawValue)] \(finding.path):\(lines)\(title)\n"
                out += limited(finding.body, findingLimit)
                    .split(separator: "\n", omittingEmptySubsequences: false).map { "  \($0)" }.joined(separator: "\n") + "\n"
            }
        }
        if cut { out += "\nSome text was cut short; get_review with full true shows all of it.\n" }
        return out
    }

    static func started(_ result: ReviewResult, forced: Bool) -> String {
        let pr = result.pr
        let name = pr.local.map { "the local changes in \($0.root)" } ?? "\(pr.nameWithOwner)#\(pr.number)"
        guard let state = result.review, state.headSha == pr.headSha else {
            return "\(name) was not queued for review. Call status to check PRBar."
        }
        switch state.status {
        case .queued, .running:
            return "Review of \(name)\(pr.local == nil ? " at \(pr.headSha.prefix(7))" : "") is \(state.status.isInFlight && !forced ? "queued or running" : "queued"). It usually takes a few minutes.\n\nNext: watch with \(argument(pr)) waits for it to finish; then call get_review with \(argument(pr))."
        case .completed:
            return "\(name) was already reviewed \(pr.local == nil ? "at \(pr.headSha.prefix(7))" : "with exactly these changes"); pass force true to review it again.\n\n" + review(result)
        case .skipped(let reason):
            return "\(name) was not reviewed: \(reason.detail) Pass force true to review it anyway."
        case .failed(let message):
            return "The review of \(name) failed: \(message)"
        }
    }

    static func watched(
        _ events: [APIEvent], cursor: Int, dropped: Bool, serverGone: Bool, subject: String?, waited: TimeInterval
    ) -> String {
        var lines: [String] = []
        if dropped { lines.append("Some events were dropped: more arrived since that cursor than PRBar keeps.") }
        if events.isEmpty {
            lines.append(serverGone
                ? "The PRBar server went away. Call watch again once it's back (status says whether it is)."
                : "Nothing happened\(subject.map { " to \($0)" } ?? "") in \(Int(waited))s.")
        }
        for event in events {
            let subject = event.pr ?? event.prNodeId ?? "a PR"
            switch event.kind {
            case .inboxChanged: lines.append("inbox: now \(event.count ?? 0) PRs")
            case .reviewSettled: lines.append("review finished: \(subject)\(event.detail.map { ", \($0)" } ?? "")")
            case .actionCompleted: lines.append("GitHub action done: \(subject)")
            case .configChanged: lines.append("prbar.yaml changed")
            }
        }
        if events.contains(where: { $0.kind == .reviewSettled }) {
            lines.append("\nNext: get_review for the findings.")
        }
        lines.append("\ncursor: \(cursor) (pass as since to the next watch)")
        return lines.joined(separator: "\n")
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
    var instructions = "PRBar reviews the user's GitHub pull requests with an AI reviewer and tracks their review inbox. On a PR you are working on: get_review to read PRBar's findings, fix them, push, run_review, then watch with that pr until the review finishes. status says what the user lets agents do."
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

struct GetReviewArgs: Decodable, Sendable {
    var pr: String?
    var path: String?
    var full: Bool?
}

struct WatchArgs: Decodable, Sendable {
    var pr: String?
    var path: String?
    var since: Int?
    var timeoutSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case pr, path, since
        case timeoutSeconds = "timeout_seconds"
    }
}

/// An argument's JSON type, for checking it against the tool's schema.
enum MCPArgumentValue: Decodable, Sendable, Equatable {
    case null, bool, integer, number
    case string(String)
    case other

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if (try? c.decode(Bool.self)) != nil {
            self = .bool
        } else if (try? c.decode(Int.self)) != nil {
            self = .integer
        } else if (try? c.decode(Double.self)) != nil {
            self = .number
        } else if let text = try? c.decode(String.self) {
            self = .string(text)
        } else {
            self = .other
        }
    }
}

struct RunReviewArgs: Decodable, Sendable {
    var pr: String?
    var path: String?
    var base: String?
    var force: Bool?
}

struct HistoryArgs: Decodable, Sendable {
    enum Kind: String, Decodable, Sendable {
        case reviews, actions
    }
    var kind: Kind?
    var limit: Int?
}
