import Foundation

/// `ReviewProvider` backed by the locally-installed `claude` CLI (Claude Code).
/// Spawns `claude -p --output-format stream-json --verbose --json-schema …`,
/// pipes the user prompt via stdin, parses the JSONL stream with
/// `ClaudeStreamParser`, and returns a `ProviderResult`.
struct ClaudeProvider: ReviewProvider {
    var id: String { "claude" }
    var displayName: String { "Claude" }

    /// Test seam: the `claude` to run instead of the one on the search path.
    var executablePath: String? = nil

    /// A review concluded on budget covered only part of the change, so it
    /// must not clear any gate that acts on its own: this sits under the
    /// auto-approve and auto-deny floors, and at share-findings' floor so
    /// what it found still reaches the author.
    static let wrapUpConfidenceCeiling = 0.5

    /// The result `subtype` claude ends with when `--max-budget-usd` stops it.
    static let budgetStopSubtype = "error_max_budget_usd"

    static let wrapUpPrompt = """
        You have reached your review budget. Do not run any more tools. \
        Based only on what you have already read, return your final review \
        now via StructuredOutput. Report the findings you verified, and say \
        in the summary which parts of the change you did not get to. Do not \
        approve a change you did not finish reading.
        """

    /// What the conclusion round may spend on top of the cap. It is one
    /// answer from a cached prefix, so a few cents in practice; the margin
    /// only keeps a long transcript from being cut off.
    static func wrapUpAllowance(cap: Double) -> Double {
        max(0.25, cap * 0.1)
    }

    enum Session: Sendable, Hashable {
        case start(String)
        case resume(String)
    }

    private struct Run {
        let result: ProcessResult
        let state: ClaudeStreamState
        let stream: String
    }

    private func run(
        _ claudePath: String,
        args: [String],
        cwd: URL?,
        stdin: String,
        options: ProviderOptions,
        onProgress: (@Sendable (ReviewProgress) -> Void)?
    ) async throws -> Run {
        let live = LiveState()
        let result = try await ProcessRunner.runStreaming(
            executable: claudePath,
            args: args,
            cwd: cwd,
            environment: ProcessRunner.inheritedEnvironment(overrides: options.environment),
            stdin: Data(stdin.utf8),
            timeout: options.timeout
        ) { line in
            onProgress?(live.consume(line: line))
            return .keepRunning
        }
        let stream = result.stdoutString ?? ""
        return Run(result: result, state: ClaudeStreamParser.parseFull(stream), stream: stream)
    }

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
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty
                    ? "claude exited \(code) without saying why."
                    : "claude exited \(code): \(detail.prefix(400))"
            case .noResultEvent:
                return "claude finished without a result event (output truncated?)."
            case .isError(let reason):
                return "claude reported an error: \(reason)"
            case .missingStructuredOutput:
                return "claude returned no structured_output (--json-schema may have failed validation)."
            case .decodeFailed(let msg):
                return "Could not decode claude's structured_output: \(msg.prefix(400))"
            case .budgetExceeded(let detail):
                // Names the setting, not just the number: the original
                // "exceeded budget: $1.0031 spent (cap $1.00)" left people
                // hunting for a cap that only existed on a repo rule.
                return "claude review stopped by the per-subreview cost cap — \(detail). "
                    + "Raise \"Max cost / subreview\" in Settings → Review defaults."
            }
        }
    }

    func availability() async -> ProviderAvailability {
        guard ExecutableResolver.find("claude") != nil else {
            return .notInstalled
        }
        return .ready
    }

    func review(
        bundle: PromptBundle,
        options: ProviderOptions,
        onProgress: (@Sendable (ReviewProgress) -> Void)? = nil
    ) async throws -> ProviderResult {
        guard let claudePath = executablePath ?? ExecutableResolver.find("claude") else {
            throw ClaudeError.notInstalled
        }

        let cwd = Self.resolveCwd(bundle: bundle, options: options)
        defer { Self.cleanupCwd(cwd, options: options) }

        // Our own session id, so a run stopped by its budget can be resumed.
        let sessionID = UUID().uuidString.lowercased()
        // The user prompt goes via stdin (it's typically 5–20 KB and we
        // don't want to hit argv size limits).
        let first = try await run(
            claudePath, args: Self.buildArgs(bundle: bundle, options: options, session: .start(sessionID)),
            cwd: cwd, stdin: bundle.userPrompt, options: options, onProgress: onProgress
        )
        var state = first.state
        var stream = first.stream
        var concludedOnBudget = false

        if state.subtype == Self.budgetStopSubtype {
            // `--max-budget-usd` is checked between turns, so the run can
            // overshoot by one turn, and that turn's tool results are lost.
            // Everything before it is in the session: resume it for one
            // answer with the same flags, so the cached prefix is reused and
            // the round costs cents. `total_cost_usd` stays cumulative.
            var wrapUp = options
            wrapUp.maxCostUsd = options.maxCostUsd + Self.wrapUpAllowance(cap: options.maxCostUsd)
            let second = try await run(
                claudePath, args: Self.buildArgs(bundle: bundle, options: wrapUp, session: .resume(sessionID)),
                cwd: cwd, stdin: Self.wrapUpPrompt, options: options, onProgress: onProgress
            )
            let spent = second.state.costUsd ?? state.costUsd ?? 0
            guard second.state.receivedResult, second.state.isError != true,
                  second.state.structuredOutput != nil || !second.state.structuredOutputAttempts.isEmpty
            else {
                throw ClaudeError.budgetExceeded(String(
                    format: "$%.4f spent (cap $%.2f), and the review could not be concluded from what it had read",
                    spent, options.maxCostUsd
                ))
            }
            var merged = second.state
            merged.toolCallCount += state.toolCallCount
            merged.toolNamesUsed = state.toolNamesUsed + merged.toolNamesUsed
            merged.apiKeySource = merged.apiKeySource ?? state.apiKeySource
            state = merged
            stream += second.stream
            concludedOnBudget = true
        } else {
            guard first.result.succeeded else {
                // claude reports API and login errors as a result event on
                // stdout and exits 1 with stderr empty.
                let stderr = first.result.stderrString ?? ""
                let reported = state.isError == true ? (state.apiErrorStatus ?? state.resultText) : nil
                throw ClaudeError.execFailed(
                    stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? reported ?? "" : stderr,
                    exitCode: first.result.exitCode
                )
            }
            guard state.receivedResult else {
                throw ClaudeError.noResultEvent
            }
            if state.isError == true {
                let reason = state.apiErrorStatus ?? state.resultText ?? "unknown"
                throw ClaudeError.isError(reason: reason)
            }
        }

        // No cost check here: claude enforces the cap itself, and a review
        // that finished one turn over it is paid for and worth keeping.
        if state.structuredOutput == nil && state.structuredOutputAttempts.isEmpty {
            throw ClaudeError.missingStructuredOutput
        }

        // Recover the substantive review even when the CLI's final answer
        // degraded to a placeholder — see StructuredOutputRecovery.
        guard let decoded = StructuredOutputRecovery.best(
            final: state.structuredOutput,
            attempts: state.structuredOutputAttempts
        ) else {
            throw ClaudeError.decodeFailed(
                "no decodable structured output among final + \(state.structuredOutputAttempts.count) attempts"
            )
        }

        return ProviderResult(
            verdict: decoded.verdict,
            confidence: concludedOnBudget ? min(decoded.confidence, Self.wrapUpConfidenceCeiling) : decoded.confidence,
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

    static func buildArgs(bundle: PromptBundle, options: ProviderOptions, session: Session? = nil) -> [String] {
        var args: [String] = [
            "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--permission-mode", "plan",
            "--append-system-prompt", bundle.systemPrompt,
            "--max-budget-usd", String(format: "%.2f", options.maxCostUsd),
        ]

        switch session {
        case .start(let id): args.append(contentsOf: ["--session-id", id])
        case .resume(let id): args.append(contentsOf: ["--resume", id])
        case nil: break
        }

        if !bundle.sessionLabel.isEmpty {
            args.append(contentsOf: ["--name", bundle.sessionLabel])
        }

        if let schemaString = String(data: options.schema, encoding: .utf8) {
            args.append(contentsOf: ["--json-schema", schemaString])
        }

        if let model = options.model {
            args.append(contentsOf: ["--model", model])
        }

        if let effort = options.effort {
            args.append(contentsOf: ["--effort", effort])
        }

        switch options.toolMode {
        case .sandboxed:
            // The AI explores a real worktree with git/grep/read instead of
            // an inlined diff. The macOS Seatbelt sandbox enforces
            // read-only (writes only inside the disposable worktree cwd)
            // and no-network at the OS level, so broad `Bash` is safe — the
            // boundary contains it. Verified headless under
            // `--permission-mode plan`: sandboxed git/grep/curl probes ran
            // without prompts; writes outside cwd and network were blocked.
            // `autoAllowBashIfSandboxed` (default) avoids per-command
            // prompts that would otherwise auto-deny in `-p` mode. The
            // mutation/agent tools stay disallowed as defense in depth.
            // network.allowedDomains:[] requests no egress (the blobs are
            // prefetched, so the review needs none); note user-level
            // settings may still merge in their own allowed domains.
            args.append(contentsOf: [
                "--settings",
                #"{"sandbox":{"enabled":true,"autoAllowBashIfSandboxed":true,"network":{"allowedDomains":[]}}}"#,
            ])
            // StructuredOutput must be allowlisted too: recent claude CLI
            // versions require an explicit tool call to emit
            // --json-schema output (a synthetic "[structured-output-enforce]"
            // message repeats otherwise) instead of validating the final
            // text — without it here the review can never complete when the
            // model hesitates on an edge case, since --allowedTools is a
            // strict allowlist.
            args.append(contentsOf: ["--allowedTools", "Bash,Read,Glob,Grep,StructuredOutput"])
            args.append(contentsOf: [
                "--disallowedTools",
                "Edit,Write,Task,Agent,NotebookEdit,TodoWrite",
            ])
            args.append(contentsOf: ["--add-dir", bundle.workdir.path])
            if let bare = options.repoBarePath {
                args.append(contentsOf: ["--add-dir", bare.path])
            }
            for extra in options.additionalAddDirs {
                args.append(contentsOf: ["--add-dir", extra.path])
            }
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
        case .sandboxed, .minimal:
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

    // MARK: - live streaming state

    /// Lock-guarded mutable state for the streaming run. Per-event
    /// callbacks fire from the readability handler thread; we serialise
    /// updates here and emit a `ReviewProgress` snapshot for each event.
    private final class LiveState: @unchecked Sendable {
        private let lock = NSLock()
        private var state = ClaudeStreamState()

        func consume(line: String) -> ReviewProgress {
            lock.lock()
            defer { lock.unlock() }
            ClaudeStreamParser.parseEvent(line: line, into: &state)
            return ReviewProgress(
                toolCallCount: state.toolCallCount,
                toolNamesUsed: state.toolNamesUsed,
                costUsdSoFar: state.costUsd,
                lastAssistantText: state.resultText
            )
        }
    }

    // structured_output decoding lives in ProviderStructuredOutput.swift —
    // shared between ClaudeProvider and CodexProvider.
}
