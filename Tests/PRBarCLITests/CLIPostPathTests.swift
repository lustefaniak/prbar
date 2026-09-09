import XCTest
@testable import PRBarCore

/// File scope: the fetcher closures are `@Sendable` and cannot reach a
/// `@MainActor`-isolated static.
private let postPathDiff = """
diff --git a/a.go b/a.go
index abc..def 100644
--- a/a.go
+++ b/a.go
@@ -1,2 +1,3 @@
 package a
+var x = 1
"""

/// The CLI's *posting* path, which `CLIRunnerTests` deliberately never
/// reaches — every case there is a gate that must cost nothing.
///
/// Two things this covers are invisible when they break: a post without
/// the verdict marker makes every other PRBar instance re-review the same
/// SHA, and a runner that stops waiting too early exits mid-`gh`.
@MainActor
final class CLIPostPathTests: XCTestCase {

    /// `PRBarVerdictMarker.append` lives in `ActionQueue`, which is
    /// app-only and not in PRBarCore — so the CLI has to apply it itself
    /// or its posts are invisible to the cross-instance dedup.
    func testAutoPostCarriesTheVerdictMarker() async {
        let posted = Recorder()
        var config = CLIConfig()
        config.defaults.aiReviewEnabled = true
        config.defaults.autoApprove = Self.permissiveApprove

        var runner = Runner(
            config: config,
            diffFetcher: { _, _, _ in postPathDiff },
            reviewThreadFetcher: { _, _, _ in
                ReviewThreadPage(threads: [], viewerLogin: "me", headRefOid: "abc1234")
            }
        )
        runner.provider = StubReviewProvider()
        runner.reviewPoster = { _, _, body, _ in await posted.set(body) }

        let outcome = await runner.review(
            pr: Self.pr(), force: true, providerOverride: nil
        )

        let body = await posted.value
        XCTAssertNotNil(body, "the run should have posted; outcome: \(outcome.note)")
        XCTAssertTrue(
            PRBarVerdictMarker.matches(sha: "abc1234", in: body ?? ""),
            "an automated CLI post must carry the head-SHA marker"
        )
    }

    /// The runner must not return until the write it registered finished —
    /// `fireBatch` clears its staging flags before the post starts, so a
    /// check against those could see "nothing pending" mid-write.
    func testRunnerWaitsForAnInFlightPost() async {
        let finished = Recorder()
        var config = CLIConfig()
        config.defaults.autoApprove = Self.permissiveApprove

        var runner = Runner(
            config: config,
            diffFetcher: { _, _, _ in postPathDiff },
            reviewThreadFetcher: { _, _, _ in
                ReviewThreadPage(threads: [], viewerLogin: "me", headRefOid: "abc1234")
            }
        )
        runner.provider = StubReviewProvider()
        runner.reviewPoster = { _, _, _, _ in
            try? await Task.sleep(for: .milliseconds(120))
            await finished.set("done")
        }

        _ = await runner.review(pr: Self.pr(), force: true, providerOverride: nil)

        let done = await finished.value
        XCTAssertEqual(done, "done", "the runner returned while the post was still in flight")
    }


    /// Every gate wide open, so the test exercises the *post* rather than
    /// re-testing `AutoReviewPolicy`.
    private static var permissiveApprove: AutoApproveConfig {
        var c = AutoApproveConfig()
        c.enabled = true
        c.minConfidence = 0.0
        c.claudeMinConfidence = 0.0
        c.codexMinConfidence = 0.0
        c.maxAnnotationSeverity = .blocker
        c.maxAnnotations = 0
        c.maxAdditions = 0
        c.maxDeletions = 0
        c.maxChangedFiles = 0
        return c
    }

    private static func pr() -> InboxPR {
        InboxPR(
            nodeId: "PR_post", owner: "o", repo: "r", number: 1,
            title: "test", body: "", url: URL(string: "https://github.com/o/r/pull/1")!,
            author: "someone", headRef: "feature", baseRef: "main",
            headSha: "abc1234", isDraft: false, role: .reviewRequested,
            mergeable: "MERGEABLE", mergeStateStatus: "CLEAN", reviewDecision: nil,
            checkRollupState: "SUCCESS", totalAdditions: 1, totalDeletions: 0,
            changedFiles: 1, hasAutoMerge: false, autoMergeEnabledBy: nil,
            allCheckSummaries: [], viewerLogin: "me",
            allowedMergeMethods: [.squash], autoMergeAllowed: false,
            deleteBranchOnMerge: true
        )
    }
}

private actor Recorder {
    private(set) var value: String?
    func set(_ v: String) { value = v }
}

/// Never spawns anything. A CLI test that reached the real provider would
/// make a paid API call on every run.
private struct StubReviewProvider: ReviewProvider {
    let id = "claude"
    let displayName = "Claude (stub)"

    func availability() async -> ProviderAvailability { .ready }

    func review(
        bundle: PromptBundle,
        options: ProviderOptions,
        onProgress: (@Sendable (ReviewProgress) -> Void)?
    ) async throws -> ProviderResult {
        ProviderResult(
            verdict: .approve,
            confidence: 0.99,
            summaryMarkdown: "looks fine",
            annotations: [],
            costUsd: 0,
            toolCallCount: 0,
            toolNamesUsed: [],
            rawJson: Data("{}".utf8)
        )
    }
}
