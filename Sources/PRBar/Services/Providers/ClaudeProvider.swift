import Foundation

/// `ReviewProvider` backed by the locally-installed `claude` CLI (Claude Code).
/// Spawns `claude -p --output-format stream-json --verbose --json-schema …`,
/// pipes the user prompt via stdin, parses the JSONL stream with
/// `ClaudeStreamParser`, and returns a `ProviderResult`.
struct ClaudeProvider: ReviewProvider {
    var id: String { "claude" }
    var displayName: String { "Claude" }

    enum ClaudeError: Error, LocalizedError, Sendable {
        case notInstalled
        case execFailed(stderr: String, exitCode: Int32)
        case noResultEvent
        case isError(reason: String)
        case missingStructuredOutput
        case decodeFailed(String)
        case budgetExceeded(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "claude CLI not found. Install Claude Code, then `claude login`."
            case .execFailed(let stderr, let code):
                return "claude exited \(code): \(stderr.prefix(400))"
            case .noResultEvent:
                return "claude finished without a result event (output truncated?)."
            case .isError(let reason):
                return "claude reported an error: \(reason)"
            case .missingStructuredOutput:
                return "claude returned no structured_output (--json-schema may have failed validation)."
            case .decodeFailed(let msg):
                return "Could not decode claude's structured_output: \(msg.prefix(400))"
            case .budgetExceeded(let detail):
                return "claude review exceeded budget: \(detail)"
            }
        }
    }

    func availability() async -> ProviderAvailability {
        guard ExecutableResolver.find("claude") != nil else {
            return .notInstalled
        }
        return .ready
    }

    func review(bundle: PromptBundle, options: ProviderOptions) async throws -> ProviderResult {
        guard let claudePath = ExecutableResolver.find("claude") else {
            throw ClaudeError.notInstalled
        }

        let args = Self.buildArgs(bundle: bundle, options: options)
        let cwd = Self.resolveCwd(bundle: bundle, options: options)
        defer { Self.cleanupCwd(cwd, options: options) }

        // The user prompt goes via stdin (it's typically 5–20 KB and we
        // don't want to hit argv size limits).
        let stdin = Data(bundle.userPrompt.utf8)

        let result = try await ProcessRunner.run(
            executable: claudePath,
            args: args,
            cwd: cwd,
            stdin: stdin
        )

        guard result.succeeded else {
            throw ClaudeError.execFailed(
                stderr: result.stderrString ?? "",
                exitCode: result.exitCode
            )
        }

        let stream = result.stdoutString ?? ""
        let state = ClaudeStreamParser.parseFull(stream)

        guard state.receivedResult else {
            throw ClaudeError.noResultEvent
        }
        if state.isError == true {
            let reason = state.apiErrorStatus ?? state.resultText ?? "unknown"
            throw ClaudeError.isError(reason: reason)
        }

        // Post-hoc budget check (live enforcement is a planned follow-up
        // that requires a streaming reader, not the current temp-file
        // approach in ProcessRunner).
        //
        // Cost cap throws — that's real money, and users must opt-in to
        // higher caps explicitly.
        //
        // Tool-call cap does NOT throw post-hoc. claude in plan mode can
        // fire ambient tools (Skill, Monitor, MCP integrations) we don't
        // enumerate in --disallowedTools, and they tend to make 1–2
        // calls before settling. The count is recorded on the result so
        // the user sees it; live enforcement (Phase 2e+) will SIGTERM
        // mid-run if tool count balloons.
        let budget = ClaudeStreamParser.budgetVerdict(
            state: state,
            maxToolCalls: options.maxToolCalls,
            maxCostUsd: options.maxCostUsd
        )
        if case .costExceeded(let cost, let max) = budget {
            throw ClaudeError.budgetExceeded(String(format: "$%.4f spent (cap $%.2f)", cost, max))
        }

        guard let soData = state.structuredOutput else {
            throw ClaudeError.missingStructuredOutput
        }

        let decoded: StructuredOutput
        do {
            decoded = try JSONDecoder().decode(StructuredOutput.self, from: soData)
        } catch {
            throw ClaudeError.decodeFailed(String(describing: error))
        }

        return ProviderResult(
            verdict: decoded.verdict,
            confidence: decoded.confidence,
            summaryMarkdown: decoded.summary,
            annotations: decoded.annotations,
            costUsd: state.costUsd,
            toolCallCount: state.toolCallCount,
            toolNamesUsed: state.toolNamesUsed,
            rawJson: Data(stream.utf8),
            isSubscriptionAuth: state.isSubscriptionAuth
        )
    }

    // MARK: - argv assembly (extracted for testing)

    static func buildArgs(bundle: PromptBundle, options: ProviderOptions) -> [String] {
        var args: [String] = [
            "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--permission-mode", "plan",
            "--append-system-prompt", bundle.systemPrompt,
        ]

        if let schemaString = String(data: options.schema, encoding: .utf8) {
            args.append(contentsOf: ["--json-schema", schemaString])
        }

        if let model = options.model {
            args.append(contentsOf: ["--model", model])
        }

        switch options.toolMode {
        case .none:
            // Best-effort deny list. The hardest guarantee is that --permission-mode
            // plan blocks state-changing tools regardless. We additionally disallow
            // the known tool names so the AI doesn't even attempt them.
            args.append(contentsOf: [
                "--disallowedTools",
                "Bash,Edit,Write,Read,Glob,Grep,WebFetch,WebSearch,Task,Agent,NotebookEdit,TodoWrite",
            ])
        case .minimal:
            // Allow read-only file tools + web verification. Network mutations
            // and process-spawning stay disallowed.
            args.append(contentsOf: [
                "--disallowedTools",
                "Bash,Edit,Write,Task,Agent,NotebookEdit,TodoWrite",
            ])
            args.append(contentsOf: ["--add-dir", bundle.workdir.path])
            for extra in options.additionalAddDirs {
                args.append(contentsOf: ["--add-dir", extra.path])
            }
        }

        return args
    }

    static func resolveCwd(bundle: PromptBundle, options: ProviderOptions) -> URL? {
        switch options.toolMode {
        case .minimal:
            return bundle.workdir
        case .none:
            // Fresh empty temp dir — even if a tool sneaks through there's
            // nothing to read or write. Caller is responsible for cleanup
            // via cleanupCwd(_:) below.
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("prbar-cwd-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            return tmp
        }
    }

    /// Removes a temp cwd created for `.none` mode. No-op when path doesn't
    /// look like one we created (defensive).
    static func cleanupCwd(_ url: URL?, options: ProviderOptions) {
        guard options.toolMode == .none, let url else { return }
        guard url.lastPathComponent.hasPrefix("prbar-cwd-") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - structured_output decoding

    private struct StructuredOutput: Decodable {
        let verdict: ReviewVerdict
        let confidence: Double
        let summary: String
        let annotations: [DiffAnnotation]
    }
}
