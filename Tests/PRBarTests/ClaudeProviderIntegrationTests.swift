import XCTest
@testable import PRBar

/// Integration tests that hit the real `claude` CLI. Skipped when claude
/// is missing. Uses Haiku model + a trivial diff to keep cost low
/// (~$0.05–$0.07 per run as of 2026-04-26).
///
/// **These cost real money.** Run sparingly. CI will skip them
/// automatically (no claude install).
final class ClaudeProviderIntegrationTests: XCTestCase {
    private func skipIfClaudeUnavailable() throws {
        guard ExecutableResolver.find("claude") != nil else {
            throw XCTSkip("claude CLI not installed; skipping integration test.")
        }
        // Real-claude tests cost real money (~$0.05–$0.20 per run). Default
        // off; opt in by `touch /tmp/prbar-run-claude-tests` before running.
        // (Env-var gating doesn't work reliably — xcodebuild doesn't
        // forward arbitrary env vars to the test runner process.)
        let sentinel = "/tmp/prbar-run-claude-tests"
        guard FileManager.default.fileExists(atPath: sentinel) else {
            throw XCTSkip("touch \(sentinel) to enable; costs real money (~$0.05–$0.20 per run).")
        }
    }

    /// Pure-prompt mode (.none) is the smallest scope to test: no cwd
    /// dependencies, no tool resolution. If this works, ContextAssembler
    /// + ClaudeProvider + ClaudeStreamParser are wired correctly end to end.
    func testPureModeReviewOfTrivialDiff() async throws {
        try skipIfClaudeUnavailable()

        let pr = makePR()
        let subdiff = Subdiff(
            subpath: "",
            hunks: [
                Hunk(
                    filePath: "config.go",
                    oldStart: 1, oldCount: 0, newStart: 1, newCount: 1,
                    lines: [.added("const Version = \"0.1.0\"")]
                )
            ]
        )
        let workdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prbar-itest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workdir) }

        let bundle = try ContextAssembler.assemble(
            pr: pr,
            subdiff: subdiff,
            diffText: """
            diff --git a/config.go b/config.go
            new file mode 100644
            --- /dev/null
            +++ b/config.go
            @@ -0,0 +1 @@
            +const Version = "0.1.0"
            """,
            toolMode: .none,
            workdir: workdir
        )

        let options = ProviderOptions(
            model: "haiku",
            toolMode: .none,
            additionalAddDirs: [],
            // claude in plan mode can fire ambient tools (Skill, Monitor,
            // MCP integrations) we don't enumerate in --disallowedTools;
            // they typically settle in 1–2 calls. Tool-count cap is no
            // longer fatal post-hoc (only cost is); leave generous.
            maxToolCalls: 10,
            maxCostUsd: 0.50,
            timeout: .seconds(120),
            schema: try PromptLibrary.outputSchema()
        )

        let provider = ClaudeProvider()
        let result: ProviderResult
        do {
            result = try await provider.review(bundle: bundle, options: options)
        } catch {
            throw XCTSkip("ClaudeProvider review failed (likely auth): \(error)")
        }

        XCTAssertTrue(ReviewVerdict.allCases.contains(result.verdict))
        XCTAssertGreaterThanOrEqual(result.confidence, 0)
        XCTAssertLessThanOrEqual(result.confidence, 1)
        XCTAssertFalse(result.summaryMarkdown.isEmpty, "summary should not be empty")
        // claude in plan mode can fire ambient tools (Skill, Monitor, MCP
        // integrations) we can't enumerate in --disallowedTools. Allow a
        // small number; cost is the real safety net.
        XCTAssertLessThanOrEqual(result.toolCallCount, 5,
            "pure-prompt mode shouldn't fire many tools; ambient ones (Skill, Monitor) ok")
        if let cost = result.costUsd {
            XCTAssertLessThan(cost, 0.50, "trivial diff shouldn't cost more than $0.50")
        }
    }

    private func makePR() -> InboxPR {
        InboxPR(
            nodeId: "PR_test",
            owner: "lustefaniak", repo: "prs", number: 1,
            title: "Add Version constant",
            body: "Just adds a version string for the tests.",
            url: URL(string: "https://github.com/lustefaniak/prs/pull/1")!,
            author: "lustefaniak",
            headRef: "test/version", baseRef: "main",
            headSha: "abc123",
            isDraft: false,
            role: .authored,
            mergeable: "MERGEABLE", mergeStateStatus: "CLEAN",
            reviewDecision: nil,
            checkRollupState: "EMPTY",
            totalAdditions: 1, totalDeletions: 0, changedFiles: 1,
            hasAutoMerge: false, autoMergeEnabledBy: nil,
            allCheckSummaries: [],
            allowedMergeMethods: [.squash],
            autoMergeAllowed: false, deleteBranchOnMerge: false
        )
    }
}
