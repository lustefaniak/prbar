import XCTest
@testable import PRBarCore

/// Drives `Runner` itself, which the parsing tests never did — the reason
/// a hang on the tool's own default path reached review. Every case here
/// must finish without either fetch closure being called: a gate that
/// rejects a PR is supposed to cost nothing.
@MainActor
final class CLIRunnerTests: XCTestCase {
    /// No in-process timeout guards these: a task parked on a
    /// continuation that never resumes cannot be cancelled, so any such
    /// helper would hang alongside it. `timeout-minutes` on the CI job is
    /// the backstop, and brahmanda's `step_timeout` is the one in
    /// production.
    private func review(
        _ runner: Runner, pr: InboxPR, force: Bool = false
    ) async -> Runner.Outcome {
        await runner.review(pr: pr, force: force, providerOverride: nil)
    }

    private func runner(_ config: CLIConfig) -> Runner {
        Runner(
            config: config,
            diffFetcher: { _, _, _ in
                XCTFail("a skipped PR must not fetch its diff")
                return ""
            },
            reviewThreadFetcher: { _, _, _ in
                XCTFail("a skipped PR must not fetch review threads")
                throw TestStop.unexpected
            }
        )
    }

    private enum TestStop: Error { case unexpected }

    func testAIDisabledSkipReturnsInsteadOfHanging() async {
        var config = CLIConfig()
        config.defaults.aiReviewEnabled = false

        let outcome = await review(runner(config), pr: Self.pr())

        XCTAssertFalse(outcome.isFailure)
        XCTAssertTrue(outcome.note.contains("skipped"), "got: \(outcome.note)")
    }

    func testDraftSkipReturnsInsteadOfHanging() async {
        var config = CLIConfig()
        config.defaults.reviewDrafts = false

        let outcome = await review(runner(config), pr: Self.pr(isDraft: true))

        XCTAssertFalse(outcome.isFailure)
        XCTAssertTrue(outcome.note.contains("draft"), "got: \(outcome.note)")
    }

    func testVerdictAlreadyAtHeadSkipReturnsInsteadOfHanging() async {
        let outcome = await review(
            runner(CLIConfig()), pr: Self.pr(hasPRBarVerdictAtHead: true))

        XCTAssertFalse(outcome.isFailure)
        XCTAssertTrue(outcome.note.contains("skipped"), "got: \(outcome.note)")
    }

    func testRoleWithoutAReviewRequestIsReportedAsSuch() async {
        let outcome = await review(runner(CLIConfig()), pr: Self.pr(role: .authored))

        XCTAssertFalse(outcome.isFailure)
        XCTAssertTrue(outcome.note.contains("no review request"), "got: \(outcome.note)")
    }

    /// An excluded repo leaves no review state at all, so it used to fall
    /// through to the "pass --force" advice — which does nothing for it.
    func testExcludedRepoSaysSoRatherThanSuggestingForce() async {
        var config = CLIConfig()
        config.repos = [RepoConfig(repoGlobs: ["o/r"], excluded: true)]

        let outcome = await review(runner(config), pr: Self.pr(), force: true)

        XCTAssertFalse(outcome.isFailure)
        XCTAssertTrue(outcome.note.contains("excluded"), "got: \(outcome.note)")
        XCTAssertFalse(outcome.note.contains("--force"))
    }

    /// `excludeTitlePatterns` was enforced only in `PRPoller`, which the
    /// CLI never goes through — so the shared config said skip and the
    /// worker reviewed it anyway, spending money and possibly posting.
    func testTitleExcludedSkipsWithoutFetching() async {
        var config = CLIConfig()
        config.defaults.excludeTitlePatterns = ["chore: bump *"]

        let outcome = await review(
            runner(config), pr: Self.pr(title: "chore: bump deps to 1.2.3")
        )

        XCTAssertFalse(outcome.isFailure)
        XCTAssertTrue(outcome.note.contains("title"), "got: \(outcome.note)")
    }

    func testNonMatchingTitleIsNotExcluded() async {
        var config = CLIConfig()
        config.defaults.excludeTitlePatterns = ["chore: bump *"]
        config.defaults.aiReviewEnabled = false   // stop before any fetch

        let outcome = await review(runner(config), pr: Self.pr(title: "feat: real work"))

        XCTAssertTrue(outcome.note.contains("AI review"), "got: \(outcome.note)")
    }

    private static func pr(
        role: PRRole = .reviewRequested,
        isDraft: Bool = false,
        hasPRBarVerdictAtHead: Bool = false,
        title: String = "test"
    ) -> InboxPR {
        InboxPR(
            nodeId: "PR_test", owner: "o", repo: "r", number: 1,
            title: title, body: "", url: URL(string: "https://github.com/o/r/pull/1")!,
            author: "someone", headRef: "feature", baseRef: "main",
            headSha: "abc1234", isDraft: isDraft, role: role,
            mergeable: "MERGEABLE", mergeStateStatus: "CLEAN", reviewDecision: nil,
            checkRollupState: "SUCCESS", totalAdditions: 1, totalDeletions: 0,
            changedFiles: 1, hasAutoMerge: false, autoMergeEnabledBy: nil,
            allCheckSummaries: [], hasPRBarVerdictAtHead: hasPRBarVerdictAtHead,
            allowedMergeMethods: [.squash], autoMergeAllowed: false,
            deleteBranchOnMerge: true
        )
    }
}
