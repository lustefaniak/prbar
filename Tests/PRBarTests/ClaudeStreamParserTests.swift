import XCTest
@testable import PRBar

final class ClaudeStreamParserTests: XCTestCase {
    /// Fixture captured from a real `claude -p --output-format stream-json
    /// --verbose --json-schema '{...}' --permission-mode plan --model haiku`
    /// run on 2026-04-26. Trimmed to the events we care about (system event
    /// shortened — its `tools` array is huge and irrelevant to parsing).
    private let realFixture = """
    {"type":"system","subtype":"init","session_id":"d2a6d1e3-bb31-4b1a-a694-9cfd284bcc07","model":"claude-haiku-4-5-20251001"}
    {"type":"rate_limit_event","rate_limit_info":{"status":"allowed"},"session_id":"d2a6d1e3-bb31-4b1a-a694-9cfd284bcc07"}
    {"type":"assistant","message":{"model":"claude-sonnet-4-6","id":"msg_01","type":"message","role":"assistant","content":[{"type":"text","text":""}],"stop_reason":null,"usage":{"input_tokens":4,"output_tokens":134}},"session_id":"d2a6d1e3-bb31-4b1a-a694-9cfd284bcc07"}
    {"type":"result","subtype":"success","is_error":false,"api_error_status":null,"duration_ms":4361,"num_turns":2,"result":"","stop_reason":"end_turn","session_id":"d2a6d1e3-bb31-4b1a-a694-9cfd284bcc07","total_cost_usd":0.0670366,"permission_denials":[],"structured_output":{"verdict":"approve","summary":"Trivial."},"terminal_reason":"completed"}
    """

    func testApiKeySourceDetectsSubscription() {
        let line = #"{"type":"system","subtype":"init","session_id":"x","apiKeySource":"/login managed key"}"#
        var state = ClaudeStreamState()
        ClaudeStreamParser.parseEvent(line: line, into: &state)
        XCTAssertEqual(state.apiKeySource, "/login managed key")
        XCTAssertTrue(state.isSubscriptionAuth)
    }

    func testApiKeySourceDetectsApiKey() {
        let line = #"{"type":"system","subtype":"init","session_id":"x","apiKeySource":"ANTHROPIC_API_KEY"}"#
        var state = ClaudeStreamState()
        ClaudeStreamParser.parseEvent(line: line, into: &state)
        XCTAssertEqual(state.apiKeySource, "ANTHROPIC_API_KEY")
        XCTAssertFalse(state.isSubscriptionAuth)
    }

    func testApiKeySourceMissingDefaultsToBilledSemantics() {
        let line = #"{"type":"system","subtype":"init","session_id":"x"}"#
        var state = ClaudeStreamState()
        ClaudeStreamParser.parseEvent(line: line, into: &state)
        XCTAssertNil(state.apiKeySource)
        XCTAssertFalse(state.isSubscriptionAuth)   // err on showing real cost
    }

    func testParseRealFixtureExtractsResult() {
        let state = ClaudeStreamParser.parseFull(realFixture)

        XCTAssertTrue(state.receivedResult)
        XCTAssertEqual(state.sessionID, "d2a6d1e3-bb31-4b1a-a694-9cfd284bcc07")
        XCTAssertEqual(state.isError, false)
        XCTAssertEqual(state.costUsd ?? 0, 0.0670366, accuracy: 1e-7)
        XCTAssertEqual(state.terminalReason, "completed")
        XCTAssertEqual(state.toolCallCount, 0)

        // structured_output should be parseable as our schema.
        XCTAssertNotNil(state.structuredOutput)
        struct Output: Decodable { let verdict: String; let summary: String }
        let decoded = try! JSONDecoder().decode(Output.self, from: state.structuredOutput!)
        XCTAssertEqual(decoded.verdict, "approve")
        XCTAssertEqual(decoded.summary, "Trivial.")
    }

    func testCountsToolUseBlocks() {
        let stream = """
        {"type":"system","subtype":"init","session_id":"abc"}
        {"type":"assistant","message":{"content":[{"type":"text","text":"Looking..."},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"a.go"}}]}}
        {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"file body"}]}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Grep","input":{"pattern":"foo"}}]}}
        {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"matches"}]}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"Done"}]}}
        {"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.05,"structured_output":{"verdict":"approve","summary":"x","confidence":0.9,"annotations":[]}}
        """
        let state = ClaudeStreamParser.parseFull(stream)
        XCTAssertEqual(state.toolCallCount, 2)
        XCTAssertEqual(state.toolNamesUsed, ["Read", "Grep"])
    }

    func testCapturesStructuredOutputAttempts() {
        let stream = """
        {"type":"system","subtype":"init","session_id":"abc"}
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"s1","name":"StructuredOutput","input":{"verdict":"comment","confidence":0.8,"summary":"first draft"}}]}}
        {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"s1","is_error":true,"content":"must have required property 'annotations'"}]}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"s2","name":"StructuredOutput","input":{"verdict":"approve","confidence":0.5,"summary":"test","annotations":[]}}]}}
        {"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.5,"structured_output":{"verdict":"approve","confidence":0.5,"summary":"test","annotations":[]}}
        """
        let state = ClaudeStreamParser.parseFull(stream)
        XCTAssertEqual(state.structuredOutputAttempts.count, 2)
        XCTAssertEqual(state.toolNamesUsed, ["StructuredOutput", "StructuredOutput"])
    }

    /// Full reproducer for the "test" reviews: a substantive attempt gets
    /// rejected (leaked annotations), the model degrades to a placeholder in
    /// the final `result`, and recovery pulls the real review back out of the
    /// captured attempts. Exercises parser + StructuredOutputRecovery
    /// together (the ClaudeProvider path minus the subprocess).
    func testRecoversRealReviewFromDegradedStream() throws {
        let stream = """
        {"type":"system","subtype":"init","session_id":"abc"}
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"s1","name":"StructuredOutput","input":{"verdict":"comment","confidence":0.8,"summary":"The new backoff never resets after success, so one failure permanently degrades the queue throughput.</summary>\\n<parameter name=\\"annotations\\">[]"}}]}}
        {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"s1","is_error":true,"content":"Output does not match required schema: root: must have required property 'annotations'"}]}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"s2","name":"StructuredOutput","input":{"verdict":"approve","confidence":0.5,"summary":"test","annotations":[]}}]}}
        {"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.9,"structured_output":{"verdict":"approve","confidence":0.5,"summary":"test","annotations":[]}}
        """
        let state = ClaudeStreamParser.parseFull(stream)
        let recovered = try XCTUnwrap(StructuredOutputRecovery.best(
            final: state.structuredOutput,
            attempts: state.structuredOutputAttempts
        ))
        XCTAssertEqual(recovered.verdict, .comment, "recovered verdict, not placeholder approve")
        XCTAssertTrue(recovered.summary.hasSuffix("queue throughput."))
        XCTAssertFalse(recovered.summary.contains("</summary>"))
    }

    func testGarbledLinesAreIgnored() {
        let stream = """
        {"type":"system","subtype":"init","session_id":"abc"}
        not json
        }{ malformed
        {"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.01}
        """
        let state = ClaudeStreamParser.parseFull(stream)
        XCTAssertTrue(state.receivedResult)
        XCTAssertEqual(state.costUsd ?? 0, 0.01, accuracy: 1e-7)
    }

    func testUnknownEventTypeIgnored() {
        let stream = """
        {"type":"system","subtype":"init","session_id":"x"}
        {"type":"completely_new_thing","payload":{"foo":"bar"}}
        {"type":"result","is_error":false,"total_cost_usd":0.05}
        """
        let state = ClaudeStreamParser.parseFull(stream)
        XCTAssertTrue(state.receivedResult)
        XCTAssertEqual(state.toolCallCount, 0)
    }

    func testIncrementalParseEqualsBatchParse() {
        let stream = """
        {"type":"system","subtype":"init","session_id":"x"}
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}
        {"type":"result","is_error":false,"total_cost_usd":0.07,"structured_output":{"k":"v"}}
        """
        // Batch
        let batch = ClaudeStreamParser.parseFull(stream)
        // Incremental
        var inc = ClaudeStreamState()
        for line in stream.split(separator: "\n") {
            ClaudeStreamParser.parseEvent(line: String(line), into: &inc)
        }
        XCTAssertEqual(batch.toolCallCount, inc.toolCallCount)
        XCTAssertEqual(batch.costUsd, inc.costUsd)
        XCTAssertEqual(batch.toolNamesUsed, inc.toolNamesUsed)
        XCTAssertEqual(batch.receivedResult, inc.receivedResult)
    }

    func testBudgetOkUnderLimits() {
        var s = ClaudeStreamState()
        s.toolCallCount = 5
        s.costUsd = 0.10
        XCTAssertEqual(
            ClaudeStreamParser.budgetVerdict(state: s, maxToolCalls: 10, maxCostUsd: 0.30),
            .ok
        )
    }

    func testBudgetToolCallsExceeded() {
        var s = ClaudeStreamState()
        s.toolCallCount = 11
        let v = ClaudeStreamParser.budgetVerdict(state: s, maxToolCalls: 10, maxCostUsd: 1.00)
        if case .toolCallsExceeded(let count, let max) = v {
            XCTAssertEqual(count, 11)
            XCTAssertEqual(max, 10)
        } else {
            XCTFail("expected .toolCallsExceeded, got \(v)")
        }
        XCTAssertTrue(v.shouldKill)
    }

    func testBudgetCostExceededOnlyAfterResult() {
        // Mid-stream we don't know the cost yet (no result event), so
        // cost-cap shouldn't fire even with crazy max settings.
        var s = ClaudeStreamState()
        s.toolCallCount = 1
        s.costUsd = nil
        XCTAssertEqual(
            ClaudeStreamParser.budgetVerdict(state: s, maxToolCalls: 10, maxCostUsd: 0.001),
            .ok
        )

        // Once cost arrives in the result event, the cap fires.
        s.costUsd = 0.5
        let v = ClaudeStreamParser.budgetVerdict(state: s, maxToolCalls: 10, maxCostUsd: 0.30)
        if case .costExceeded(let cost, let max) = v {
            XCTAssertEqual(cost, 0.5, accuracy: 1e-9)
            XCTAssertEqual(max, 0.30, accuracy: 1e-9)
        } else {
            XCTFail("expected .costExceeded, got \(v)")
        }
        XCTAssertTrue(v.shouldKill)
    }

    func testBudgetVerdictEqualityForAssertions() {
        // Sanity: the .ok case is Equatable so XCTAssertEqual works.
        XCTAssertEqual(ClaudeStreamParser.BudgetVerdict.ok, .ok)
    }
}
