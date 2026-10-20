import XCTest
@testable import PRBar

/// A review that runs out of budget must still produce a review: claude stops
/// with `error_max_budget_usd`, and the same session is resumed for one
/// conclusion round over what it already read.
final class ClaudeBudgetWrapUpTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prbar-claude-budget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        try await super.tearDown()
    }

    func testBudgetStopIsConcludedInTheSameSession() async throws {
        let claude = try fakeClaude([
            #"{"type":"result","subtype":"error_max_budget_usd","is_error":true,"total_cost_usd":0.35,"errors":["Reached maximum budget ($0.30)"]}"#,
            #"{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.37,"structured_output":{"verdict":"request_changes","confidence":0.9,"summary":"Partial review, f4.go to f12.go not read.","annotations":[]}}"#,
        ])
        let provider = ClaudeProvider(executablePath: claude.path)

        let result = try await provider.review(bundle: bundle(), options: options(maxCostUsd: 0.30))

        XCTAssertEqual(result.verdict, .requestChanges)
        XCTAssertEqual(result.summaryMarkdown, "Partial review, f4.go to f12.go not read.")
        XCTAssertEqual(try XCTUnwrap(result.costUsd), 0.37, accuracy: 0.0001, "total_cost_usd is cumulative across a resume")
        XCTAssertLessThanOrEqual(result.confidence, ClaudeProvider.wrapUpConfidenceCeiling)

        let calls = try recordedCalls()
        XCTAssertEqual(calls.count, 2)
        let first = calls[0], second = calls[1]
        XCTAssertEqual(value(after: "--max-budget-usd", in: first), "0.30")
        let session = try XCTUnwrap(value(after: "--session-id", in: first))
        XCTAssertEqual(value(after: "--resume", in: second), session)
        XCTAssertNil(value(after: "--session-id", in: second))
        XCTAssertEqual(value(after: "--max-budget-usd", in: second), "0.25", "the budget counts per call, so the conclusion round gets only its allowance")
    }

    func testLargeChangeAnsweredEarlyIsAskedToGoOn() async throws {
        let claude = try fakeClaude([
            answer("approve", cost: 0.30, summary: "read 2 files"),
            answer("approve", cost: 0.90, summary: "read 40 files"),
            answer("comment", cost: 1.40, summary: "read the rest that matters"),
        ])
        let provider = ClaudeProvider(executablePath: claude.path)

        let result = try await provider.review(bundle: bundle(large: true), options: options(maxCostUsd: 3, toolMode: .sandboxed))

        XCTAssertEqual(result.summaryMarkdown, "read the rest that matters")
        XCTAssertEqual(result.verdict, .comment)
        XCTAssertEqual(result.confidence, 0.9, "a review that went on by choice is not a partial one")
        XCTAssertEqual(try XCTUnwrap(result.costUsd), 1.40, accuracy: 0.0001)
        let calls = try recordedCalls()
        XCTAssertEqual(calls.count, 1 + ClaudeProvider.continueRounds)
        XCTAssertEqual(value(after: "--max-budget-usd", in: calls[1]), "2.70")
        XCTAssertEqual(value(after: "--max-budget-usd", in: calls[2]), "2.10")
        XCTAssertTrue(try stdin(ofCall: 1).contains("You have used $0.30 of your $3.00 budget"))
    }

    func testContinuingStopsOnceHalfTheBudgetIsSpent() async throws {
        let claude = try fakeClaude([answer("approve", cost: 0.30), answer("comment", cost: 1.60)])
        let provider = ClaudeProvider(executablePath: claude.path)

        let result = try await provider.review(bundle: bundle(large: true), options: options(maxCostUsd: 3, toolMode: .sandboxed))

        XCTAssertEqual(result.verdict, .comment)
        XCTAssertEqual(try recordedCalls().count, 2)
    }

    func testSmallChangeIsNotAskedToGoOn() async throws {
        let claude = try fakeClaude([answer("approve", cost: 0.10)])
        let provider = ClaudeProvider(executablePath: claude.path)

        _ = try await provider.review(bundle: bundle(large: false), options: options(maxCostUsd: 3, toolMode: .sandboxed))

        XCTAssertEqual(try recordedCalls().count, 1)
    }

    func testContinueRoundThatRunsOutOfBudgetIsConcluded() async throws {
        let claude = try fakeClaude([
            answer("approve", cost: 0.30),
            #"{"type":"result","subtype":"error_max_budget_usd","is_error":true,"total_cost_usd":3.05}"#,
            answer("request_changes", cost: 3.08, summary: "partial"),
        ])
        let provider = ClaudeProvider(executablePath: claude.path)

        let result = try await provider.review(bundle: bundle(large: true), options: options(maxCostUsd: 3, toolMode: .sandboxed))

        XCTAssertEqual(result.summaryMarkdown, "partial")
        XCTAssertLessThanOrEqual(result.confidence, ClaudeProvider.wrapUpConfidenceCeiling)
        XCTAssertEqual(try XCTUnwrap(result.costUsd), 3.08, accuracy: 0.0001)
        XCTAssertEqual(try stdin(ofCall: 2), ClaudeProvider.wrapUpPrompt)
    }

    func testCompletedReviewOverTheCapIsKept() async throws {
        let claude = try fakeClaude([answer("approve", cost: 0.42)])
        let provider = ClaudeProvider(executablePath: claude.path)

        let result = try await provider.review(bundle: bundle(), options: options(maxCostUsd: 0.30))

        XCTAssertEqual(result.verdict, .approve)
        XCTAssertEqual(result.confidence, 0.9)
        XCTAssertEqual(try recordedCalls().count, 1)
    }

    // MARK: - helpers

    private var callLog: URL { dir.appendingPathComponent("calls.log") }

    /// A `claude` stand-in: logs its argv (one call per line, args
    /// tab-separated) and its stdin, and prints the response for that call,
    /// the last one repeating.
    private func fakeClaude(_ responses: [String]) throws -> URL {
        for (i, r) in responses.enumerated() {
            try (r + "\n").write(to: dir.appendingPathComponent("response-\(i).jsonl"), atomically: true, encoding: .utf8)
        }
        let script = dir.appendingPathComponent("claude")
        try """
        #!/bin/sh
        d='\(dir.path)'
        n=$(cat "$d/count" 2>/dev/null || echo 0)
        cat > "$d/stdin-$n.txt"
        line=''
        for a in "$@"; do line="$line$a\t"; done
        printf '%b\\n' "$line" >> '\(callLog.path)'
        i=$n; while [ ! -f "$d/response-$i.jsonl" ]; do i=$((i-1)); done
        echo $((n+1)) > "$d/count"
        cat "$d/response-$i.jsonl"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func stdin(ofCall n: Int) throws -> String {
        try String(contentsOf: dir.appendingPathComponent("stdin-\(n).txt"), encoding: .utf8)
    }

    private func answer(_ verdict: String, cost: Double, summary: String = "ok") -> String {
        #"{"type":"result","subtype":"success","is_error":false,"total_cost_usd":\#(cost),"structured_output":{"verdict":"\#(verdict)","confidence":0.9,"summary":"\#(summary)","annotations":[]}}"#
    }

    private func recordedCalls() throws -> [[String]] {
        try String(contentsOf: callLog, encoding: .utf8)
            .split(separator: "\n")
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }

    private func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private func bundle(large: Bool = false) -> PromptBundle {
        PromptBundle(
            systemPrompt: "system", userPrompt: "user", workdir: dir, prNodeId: "PR_1", subpath: "",
            isLargeChange: large
        )
    }

    private func options(maxCostUsd: Double, toolMode: ToolMode = .none) -> ProviderOptions {
        ProviderOptions(
            model: nil, toolMode: toolMode, additionalAddDirs: [],
            maxToolCalls: 10, maxCostUsd: maxCostUsd, timeout: .seconds(30),
            schema: Data("{}".utf8)
        )
    }
}
