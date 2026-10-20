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
        let claude = try fakeClaude(
            firstRun: #"{"type":"result","subtype":"error_max_budget_usd","is_error":true,"total_cost_usd":0.35,"errors":["Reached maximum budget ($0.30)"]}"#,
            resumed: #"{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.37,"structured_output":{"verdict":"request_changes","confidence":0.9,"summary":"Partial review, f4.go to f12.go not read.","annotations":[]}}"#
        )
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
    }

    func testCompletedReviewOverTheCapIsKept() async throws {
        let claude = try fakeClaude(
            firstRun: #"{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.42,"structured_output":{"verdict":"approve","confidence":0.9,"summary":"Nothing worth raising.","annotations":[]}}"#,
            resumed: ""
        )
        let provider = ClaudeProvider(executablePath: claude.path)

        let result = try await provider.review(bundle: bundle(), options: options(maxCostUsd: 0.30))

        XCTAssertEqual(result.verdict, .approve)
        XCTAssertEqual(result.confidence, 0.9)
        XCTAssertEqual(try recordedCalls().count, 1)
    }

    // MARK: - helpers

    private var callLog: URL { dir.appendingPathComponent("calls.log") }

    /// A `claude` stand-in: logs its argv (one call per line, args
    /// tab-separated) and prints `resumed` when called with `--resume`,
    /// `firstRun` otherwise.
    private func fakeClaude(firstRun: String, resumed: String) throws -> URL {
        let first = dir.appendingPathComponent("first.jsonl")
        let second = dir.appendingPathComponent("resumed.jsonl")
        try (firstRun + "\n").write(to: first, atomically: true, encoding: .utf8)
        try (resumed + "\n").write(to: second, atomically: true, encoding: .utf8)
        let script = dir.appendingPathComponent("claude")
        try """
        #!/bin/sh
        cat > /dev/null
        out='\(first.path)'
        line=''
        for a in "$@"; do
          line="$line$a\t"
          [ "$a" = "--resume" ] && out='\(second.path)'
        done
        printf '%b\\n' "$line" >> '\(callLog.path)'
        cat "$out"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
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

    private func bundle() -> PromptBundle {
        PromptBundle(systemPrompt: "system", userPrompt: "user", workdir: dir, prNodeId: "PR_1", subpath: "")
    }

    private func options(maxCostUsd: Double) -> ProviderOptions {
        ProviderOptions(
            model: nil, toolMode: .none, additionalAddDirs: [],
            maxToolCalls: 10, maxCostUsd: maxCostUsd, timeout: .seconds(30),
            schema: Data("{}".utf8)
        )
    }
}
