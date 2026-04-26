import Foundation

/// `ReviewProvider` backed by the locally-installed `codex` CLI (OpenAI
/// Codex). Mirrors `ClaudeProvider`'s shape; differences:
///
/// - **No `--json-schema`** equivalent in `codex` today, so we ask the
///   model for JSON via the system prompt + a literal embedded schema
///   and parse the first JSON object we find on stdout.
/// - **No streaming budget**: codex's stdout format is less stable than
///   claude's `stream-json` so we run it through `ProcessRunner.run`
///   (full capture) and do post-hoc cost / output-shape checks. Live
///   SIGTERM-on-budget is a follow-up.
/// - **Tool restrictions** are lighter — codex's CLI surface for
///   disallowing tools varies by version, so we lean on prompt
///   discipline ("you are a judge, not a fixer") plus `.minimal` cwd
///   scoping when a workdir exists.
///
/// The actual argv assembly is intentionally conservative — codex's
/// flag surface has churned across releases. If your installed version
/// doesn't accept `exec --skip-git-repo-check`, override via the
/// `PRBAR_CODEX_BIN` env var to point at a wrapper script that
/// translates flags appropriately.
struct CodexProvider: ReviewProvider {
    var id: String { "codex" }
    var displayName: String { "Codex" }

    enum CodexError: Error, LocalizedError, Sendable {
        case notInstalled
        case execFailed(stderr: String, exitCode: Int32)
        case noJSONInOutput(rawOutput: String)
        case decodeFailed(String, rawJSON: String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "codex CLI not found. Install OpenAI Codex (`npm i -g @openai/codex`), then `codex login`."
            case .execFailed(let stderr, let code):
                return "codex exited \(code): \(stderr.prefix(400))"
            case .noJSONInOutput(let raw):
                return "codex returned no JSON object on stdout. First 400 chars: \(raw.prefix(400))"
            case .decodeFailed(let msg, _):
                return "Could not decode codex's JSON output: \(msg.prefix(400))"
            }
        }
    }

    func availability() async -> ProviderAvailability {
        guard resolveBinary() != nil else {
            return .notInstalled
        }
        return .ready
    }

    func review(
        bundle: PromptBundle,
        options: ProviderOptions,
        onProgress: (@Sendable (ReviewProgress) -> Void)? = nil
    ) async throws -> ProviderResult {
        guard let codexPath = resolveBinary() else {
            throw CodexError.notInstalled
        }

        // Codex's `--output-schema` takes a file path, so we materialise
        // the schema bytes to a tempfile. `--output-last-message` writes
        // the final model message (which, with output-schema, is the
        // JSON object) to a second tempfile we read back. Both temps
        // live in the system temp dir and are cleaned up on the way out.
        let tmp = FileManager.default.temporaryDirectory
        let schemaURL = tmp.appendingPathComponent("prbar-codex-schema-\(UUID().uuidString).json")
        let lastURL   = tmp.appendingPathComponent("prbar-codex-last-\(UUID().uuidString).txt")
        // Codex (OpenAI strict structured-output) rejects schemas that
        // don't have `additionalProperties: false` on every object —
        // *opposite* of claude, which rejects schemas that contain it.
        // Transform the shared `Resources/schemas/review.json` on the
        // fly so a single source of truth feeds both providers.
        let strictSchema = Self.addStrictAdditionalProperties(options.schema) ?? options.schema
        try strictSchema.write(to: schemaURL)
        defer {
            try? FileManager.default.removeItem(at: schemaURL)
            try? FileManager.default.removeItem(at: lastURL)
        }

        let prompt = Self.buildPrompt(bundle: bundle)
        let args = Self.buildArgs(
            options: options,
            schemaPath: schemaURL.path,
            lastMessagePath: lastURL.path,
            workdir: bundle.workdir
        )
        let result = try await ProcessRunner.run(
            executable: codexPath,
            args: args,
            stdin: Data(prompt.utf8)
        )

        guard result.succeeded else {
            throw CodexError.execFailed(
                stderr: result.stderrString ?? "",
                exitCode: result.exitCode
            )
        }

        // Prefer the `--output-last-message` file (just the final
        // message, schema-validated by codex). Fall back to scanning
        // stdout if the file is missing for any reason.
        let lastMessage = (try? String(contentsOf: lastURL, encoding: .utf8)) ?? ""
        let raw = result.stdoutString ?? ""
        let jsonSource: String
        if !lastMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            jsonSource = lastMessage
        } else {
            jsonSource = raw
        }
        guard let jsonString = Self.extractFirstJSONObject(from: jsonSource) else {
            throw CodexError.noJSONInOutput(rawOutput: jsonSource)
        }

        let decoded: ProviderStructuredOutput
        do {
            decoded = try JSONDecoder().decode(
                ProviderStructuredOutput.self,
                from: Data(jsonString.utf8)
            )
        } catch {
            throw CodexError.decodeFailed(String(describing: error), rawJSON: jsonString)
        }

        // Codex doesn't surface per-call cost in a documented stable
        // shape; report nil and let the UI gray the cost label.
        return ProviderResult(
            verdict: decoded.verdict,
            confidence: decoded.confidence,
            summaryMarkdown: decoded.summary,
            annotations: decoded.annotations,
            costUsd: nil,
            toolCallCount: 0,
            toolNamesUsed: [],
            rawJson: Data(raw.utf8),
            isSubscriptionAuth: false
        )
    }

    // MARK: - argv assembly (extracted for testing)

    /// Argv for `codex exec`. Tested against `codex 0.x`. `--output-schema`
    /// (file) and `--output-last-message` (file) are codex's first-class
    /// equivalents of claude's `--json-schema` + `result.structured_output`.
    /// Use `--cd` to set the workdir (passing cwd to ProcessRunner alone
    /// doesn't propagate through codex's session bootstrap reliably).
    static func buildArgs(
        options: ProviderOptions,
        schemaPath: String,
        lastMessagePath: String,
        workdir: URL
    ) -> [String] {
        var args: [String] = [
            "exec",
            "--skip-git-repo-check",
            "--output-schema", schemaPath,
            "--output-last-message", lastMessagePath,
            "--cd", workdir.path,
            // Read-only sandbox — the AI is a judge, not a fixer. Same
            // intent as claude's `--permission-mode plan`.
            "--sandbox", "read-only",
        ]
        if let model = options.model {
            args.append(contentsOf: ["--model", model])
        }
        // Read prompt from stdin (the `-` placeholder docs say so).
        args.append("-")
        return args
    }

    /// User+system prompt joined for stdin. Codex doesn't have a
    /// separate system-prompt flag, so we concatenate. The schema is
    /// passed via `--output-schema`, not in the prompt.
    static func buildPrompt(bundle: PromptBundle) -> String {
        var out = bundle.systemPrompt
        out += "\n\n---\n\n"
        out += bundle.userPrompt
        return out
    }

    /// Extract the first balanced `{ ... }` block from arbitrary stdout.
    /// Codex tends to print a JSON object after some preamble lines;
    /// markdown fences are stripped here too. Returns nil if no
    /// well-formed top-level object is found.
    static func extractFirstJSONObject(from text: String) -> String? {
        // Strip ```json fences if present.
        let stripped = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")

        var depth = 0
        var start: String.Index? = nil
        var inString = false
        var escape = false
        for idx in stripped.indices {
            let c = stripped[idx]
            if inString {
                if escape {
                    escape = false
                } else if c == "\\" {
                    escape = true
                } else if c == "\"" {
                    inString = false
                }
                continue
            }
            if c == "\"" {
                inString = true
                continue
            }
            if c == "{" {
                if depth == 0 { start = idx }
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0, let s = start {
                    return String(stripped[s...idx])
                }
            }
        }
        return nil
    }

    // MARK: - schema transform

    /// Walk a JSON Schema and inject `"additionalProperties": false` into
    /// every object that doesn't already specify it. Required by OpenAI
    /// strict-mode structured outputs (the underlying API codex calls).
    /// Returns nil on parse failure so the caller falls back to the raw
    /// bytes (preserves the original "no transform" behaviour).
    static func addStrictAdditionalProperties(_ schemaData: Data) -> Data? {
        guard
            let raw = try? JSONSerialization.jsonObject(with: schemaData),
            let mutated = injectAdditionalPropertiesFalse(raw),
            let out = try? JSONSerialization.data(
                withJSONObject: mutated,
                options: [.sortedKeys]
            )
        else { return nil }
        return out
    }

    /// Recursive walker. Looks for `"type":"object"` (or any object that
    /// has a `properties` map) and adds `additionalProperties: false`
    /// when missing. Recurses into nested `properties` and `items`.
    private static func injectAdditionalPropertiesFalse(_ node: Any) -> Any? {
        if var obj = node as? [String: Any] {
            // Recurse first so nested objects get the same treatment.
            if let props = obj["properties"] as? [String: Any] {
                var rewritten: [String: Any] = [:]
                for (k, v) in props {
                    rewritten[k] = injectAdditionalPropertiesFalse(v) ?? v
                }
                obj["properties"] = rewritten
            }
            if let items = obj["items"] {
                obj["items"] = injectAdditionalPropertiesFalse(items) ?? items
            }
            // Inject only on object schemas. Tells the strict mode that
            // we don't allow undeclared keys.
            let isObject = (obj["type"] as? String) == "object"
                || obj["properties"] != nil
            if isObject && obj["additionalProperties"] == nil {
                obj["additionalProperties"] = false
            }
            return obj
        }
        if let arr = node as? [Any] {
            return arr.map { injectAdditionalPropertiesFalse($0) ?? $0 }
        }
        return node
    }

    // MARK: - private

    private func resolveBinary() -> String? {
        // PRBAR_CODEX_BIN escape hatch — point at a wrapper script if
        // your codex version takes different flags than buildArgs assumes.
        if let override = ProcessInfo.processInfo.environment["PRBAR_CODEX_BIN"],
           !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        return ExecutableResolver.find("codex")
    }
}
