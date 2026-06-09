import XCTest
@testable import PRBar

final class CodexProviderTests: XCTestCase {
    func testBuildArgsIncludesExecSchemaAndCwd() {
        let opts = makeOptions(model: nil)
        let args = CodexProvider.buildArgs(
            options: opts,
            schemaPath: "/tmp/schema.json",
            lastMessagePath: "/tmp/last.txt",
            workdir: URL(fileURLWithPath: "/tmp/wd")
        )
        XCTAssertEqual(args.first, "exec")
        XCTAssertTrue(args.contains("--skip-git-repo-check"))
        XCTAssertTrue(args.contains("--output-schema"))
        XCTAssertTrue(args.contains("/tmp/schema.json"))
        XCTAssertTrue(args.contains("--output-last-message"))
        XCTAssertTrue(args.contains("/tmp/last.txt"))
        XCTAssertTrue(args.contains("--cd"))
        XCTAssertTrue(args.contains("/tmp/wd"))
        XCTAssertTrue(args.contains("--sandbox"))
        XCTAssertTrue(args.contains("read-only"),
            "sandbox should be read-only — the AI is a judge, not a fixer")
        XCTAssertEqual(args.last, "-",
            "prompt is fed via stdin (the trailing `-` placeholder)")
        XCTAssertFalse(args.contains("--model"), "no model override → no --model flag")
    }

    func testSandboxedModeStaysReadOnlyAndScopedToWorktree() {
        // In `.sandboxed`, the workdir is a real worktree and codex explores
        // it with git inside its own read-only sandbox. No argv change vs
        // other modes — the read-only + --cd boundary already does the job.
        var opts = makeOptions(model: nil)
        opts.toolMode = .sandboxed
        let args = CodexProvider.buildArgs(
            options: opts,
            schemaPath: "/tmp/schema.json",
            lastMessagePath: "/tmp/last.txt",
            workdir: URL(fileURLWithPath: "/wt/sub")
        )
        XCTAssertTrue(args.contains("--sandbox"))
        XCTAssertTrue(args.contains("read-only"))
        XCTAssertTrue(args.contains("--cd"))
        XCTAssertTrue(args.contains("/wt/sub"))
    }

    func testBuildArgsRequestsJSONEventStream() {
        let args = CodexProvider.buildArgs(
            options: makeOptions(model: nil),
            schemaPath: "/tmp/s.json", lastMessagePath: "/tmp/l.txt",
            workdir: URL(fileURLWithPath: "/wt")
        )
        XCTAssertTrue(args.contains("--json"), "need JSONL stdout to read tool activity")
    }

    func testParseToolActivityCountsAndLabelsCommands() {
        let stream = """
        {"type":"thread.started"}
        {"type":"item.completed","item":{"id":"1","type":"agent_message","text":"thinking"}}
        {"type":"item.completed","item":{"id":"2","type":"command_execution","command":"/bin/zsh -lc 'git diff abc HEAD'","exit_code":0}}
        {"type":"item.completed","item":{"id":"3","type":"command_execution","command":"/bin/zsh -lc 'grep -rn foo src'","exit_code":0}}
        not json
        {"type":"turn.completed","usage":{"input_tokens":100}}
        """
        let activity = CodexProvider.parseToolActivity(fromEventStream: stream)
        XCTAssertEqual(activity.count, 2)
        XCTAssertEqual(activity.names, ["git diff", "grep"])
    }

    func testCommandLabelStripsShellWrapper() {
        XCTAssertEqual(CodexProvider.commandLabel("/bin/zsh -lc 'git show abc:f.go'"), "git show")
        XCTAssertEqual(CodexProvider.commandLabel("/bin/sh -c 'cat README.md'"), "cat")
        XCTAssertEqual(CodexProvider.commandLabel("rg pattern"), "rg")
    }

    func testLastAgentMessageReturnsFinalText() {
        let stream = """
        {"type":"item.completed","item":{"type":"agent_message","text":"first"}}
        {"type":"item.completed","item":{"type":"command_execution","command":"x"}}
        {"type":"item.completed","item":{"type":"agent_message","text":"{\\"verdict\\":\\"approve\\"}"}}
        """
        XCTAssertEqual(CodexProvider.lastAgentMessage(fromEventStream: stream), "{\"verdict\":\"approve\"}")
    }

    func testBuildArgsAddsModelWhenSet() {
        let opts = makeOptions(model: "gpt-5")
        let args = CodexProvider.buildArgs(
            options: opts,
            schemaPath: "/tmp/schema.json",
            lastMessagePath: "/tmp/last.txt",
            workdir: URL(fileURLWithPath: "/tmp/wd")
        )
        guard let modelIdx = args.firstIndex(of: "--model") else {
            return XCTFail("--model flag not present")
        }
        XCTAssertEqual(args[modelIdx + 1], "gpt-5")
    }

    func testBuildPromptJoinsSystemAndUser() {
        let bundle = PromptBundle(
            systemPrompt: "You are a senior reviewer.",
            userPrompt:   "## Diff\n```\n+ x\n```",
            workdir:      URL(fileURLWithPath: "/tmp"),
            prNodeId:     "PR_1",
            subpath:      ""
        )
        let prompt = CodexProvider.buildPrompt(bundle: bundle)
        XCTAssertTrue(prompt.contains("You are a senior reviewer."))
        XCTAssertTrue(prompt.contains("## Diff"))
        // Schema is passed via --output-schema, not embedded in the prompt.
        XCTAssertFalse(prompt.contains("\"type\":\"object\""))
    }

    private func makeOptions(model: String?) -> ProviderOptions {
        ProviderOptions(
            model: model, toolMode: .none, additionalAddDirs: [],
            maxToolCalls: 10, maxCostUsd: 0.30,
            timeout: .seconds(120), schema: Data("{}".utf8)
        )
    }

    func testExtractFirstJSONObjectHandlesPlainJSON() {
        let json = #"{"verdict":"approve","confidence":0.9,"summary":"ok","annotations":[]}"#
        let extracted = CodexProvider.extractFirstJSONObject(from: json)
        XCTAssertEqual(extracted, json)
    }

    func testExtractFirstJSONObjectStripsCodeFences() {
        let wrapped = """
        Here's my review:

        ```json
        {"verdict":"approve","confidence":0.85,"summary":"LGTM","annotations":[]}
        ```

        That's it.
        """
        let extracted = CodexProvider.extractFirstJSONObject(from: wrapped)
        XCTAssertNotNil(extracted)
        XCTAssertTrue(extracted?.contains("\"verdict\":\"approve\"") ?? false)
        XCTAssertTrue(extracted?.hasPrefix("{") ?? false)
        XCTAssertTrue(extracted?.hasSuffix("}") ?? false)
    }

    func testExtractFirstJSONObjectFindsObjectInPreamble() {
        // Codex sometimes prints status lines before the JSON.
        let raw = """
        Reading config.go…
        Generating review…
        {"verdict":"comment","confidence":0.7,"summary":"x","annotations":[]}
        """
        let extracted = CodexProvider.extractFirstJSONObject(from: raw)
        XCTAssertNotNil(extracted)
        XCTAssertTrue(extracted?.contains("\"verdict\":\"comment\"") ?? false)
    }

    func testExtractFirstJSONObjectIgnoresBracesInsideStrings() {
        // A naive depth counter would miscount the } inside the string.
        let raw = #"{"summary":"contains } and { inside","verdict":"approve","confidence":1,"annotations":[]}"#
        let extracted = CodexProvider.extractFirstJSONObject(from: raw)
        XCTAssertEqual(extracted, raw)
    }

    func testExtractFirstJSONObjectReturnsNilForUnbalanced() {
        XCTAssertNil(CodexProvider.extractFirstJSONObject(from: "no braces here"))
        XCTAssertNil(CodexProvider.extractFirstJSONObject(from: "{ not closed"))
    }

    func testAddStrictAdditionalPropertiesInjectsOnEveryObject() throws {
        // Mirrors Resources/schemas/review.json shape — top-level object
        // with a nested array of objects.
        let original = """
        {
          "type": "object",
          "required": ["verdict", "annotations"],
          "properties": {
            "verdict": { "type": "string" },
            "annotations": {
              "type": "array",
              "items": {
                "type": "object",
                "required": ["path"],
                "properties": { "path": { "type": "string" } }
              }
            }
          }
        }
        """
        guard let out = CodexProvider.addStrictAdditionalProperties(Data(original.utf8)),
              let json = try JSONSerialization.jsonObject(with: out) as? [String: Any]
        else {
            return XCTFail("transform returned nil")
        }
        XCTAssertEqual(json["additionalProperties"] as? Bool, false,
            "top-level object must get additionalProperties:false")
        let annotations = (json["properties"] as? [String: Any])?["annotations"] as? [String: Any]
        let item = annotations?["items"] as? [String: Any]
        XCTAssertEqual(item?["additionalProperties"] as? Bool, false,
            "nested array-item objects must get the marker too")
    }

    func testAddStrictAdditionalPropertiesPreservesExistingValue() throws {
        // If the schema already specifies additionalProperties (true or
        // false), we must NOT clobber it.
        let original = """
        {
          "type": "object",
          "additionalProperties": true,
          "properties": { "x": { "type": "string" } }
        }
        """
        let out = CodexProvider.addStrictAdditionalProperties(Data(original.utf8))!
        let json = try JSONSerialization.jsonObject(with: out) as? [String: Any]
        XCTAssertEqual(json?["additionalProperties"] as? Bool, true,
            "explicit existing value must be preserved")
    }

    func testDecodeFullPipeline() throws {
        let raw = """
        Working on review…
        ```json
        {
          "verdict": "request_changes",
          "confidence": 0.78,
          "summary": "Two blockers in the goroutine path.",
          "annotations": [
            {
              "path": "worker.go",
              "line_start": 42,
              "line_end": 44,
              "severity": "blocker",
              "title": "leaks ctx",
              "body": "..."
            }
          ]
        }
        ```
        """
        guard let json = CodexProvider.extractFirstJSONObject(from: raw) else {
            return XCTFail("expected JSON to be extracted")
        }
        let decoded = try JSONDecoder().decode(
            ProviderStructuredOutput.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.verdict, .requestChanges)
        XCTAssertEqual(decoded.annotations.count, 1)
        XCTAssertEqual(decoded.annotations.first?.severity, .blocker)
    }
}
