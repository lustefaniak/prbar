import XCTest
@testable import PRBar

@MainActor
final class ContextAssemblerTests: XCTestCase {
    func testMinimalModeMentionsToolBudgetAndCwd() throws {
        let bundle = try ContextAssembler.assemble(
            pr: makePR(),
            subdiff: subdiff(subpath: "kernel-billing"),
            diffText: "diff --git a/x b/x\n@@ -1 +1 @@\n-old\n+new\n",
            toolMode: .minimal,
            workdir: URL(fileURLWithPath: "/tmp/wd")
        )
        XCTAssertTrue(bundle.userPrompt.contains("read-only access"))
        XCTAssertTrue(bundle.userPrompt.contains("Hard cap"))
        XCTAssertTrue(bundle.userPrompt.contains("cwd is set here"))
        XCTAssertEqual(bundle.workdir, URL(fileURLWithPath: "/tmp/wd"))
        XCTAssertEqual(bundle.subpath, "kernel-billing")
    }

    func testNoneModeForbidsTools() throws {
        let bundle = try ContextAssembler.assemble(
            pr: makePR(),
            subdiff: subdiff(),
            diffText: "diff",
            toolMode: .none,
            workdir: URL(fileURLWithPath: "/tmp/wd")
        )
        XCTAssertTrue(bundle.userPrompt.contains("no tool access"))
        XCTAssertFalse(bundle.userPrompt.contains("WebFetch"))
    }

    func testEmptySubpathRendersAsRepoRoot() throws {
        let bundle = try ContextAssembler.assemble(
            pr: makePR(),
            subdiff: subdiff(subpath: ""),
            diffText: "diff",
            toolMode: .minimal,
            workdir: URL(fileURLWithPath: "/tmp")
        )
        XCTAssertTrue(bundle.userPrompt.contains("Repo root"))
    }

    func testFilesChangedShowsPerFileCounts() throws {
        let s = Subdiff(
            subpath: "kernel-x",
            hunks: [
                Hunk(filePath: "kernel-x/a.go", oldStart: 1, oldCount: 0, newStart: 1, newCount: 3,
                     lines: [.added("foo"), .added("bar"), .added("baz")]),
                Hunk(filePath: "kernel-x/b.go", oldStart: 1, oldCount: 2, newStart: 1, newCount: 1,
                     lines: [.removed("old1"), .removed("old2"), .added("new")]),
            ]
        )
        let bundle = try ContextAssembler.assemble(
            pr: makePR(), subdiff: s, diffText: "<>",
            toolMode: .none, workdir: URL(fileURLWithPath: "/tmp")
        )
        XCTAssertTrue(bundle.userPrompt.contains("`kernel-x/a.go` (+3 / -0)"))
        XCTAssertTrue(bundle.userPrompt.contains("`kernel-x/b.go` (+1 / -2)"))
    }

    func testExistingCommentsRendered() throws {
        let bundle = try ContextAssembler.assemble(
            pr: makePR(),
            subdiff: subdiff(),
            diffText: "<>",
            existingComments: [
                ExistingReviewComment(author: "alice", body: "lgtm", isReview: true),
                ExistingReviewComment(author: "bob",   body: "consider buffering", isReview: false),
            ],
            toolMode: .none,
            workdir: URL(fileURLWithPath: "/tmp")
        )
        XCTAssertTrue(bundle.userPrompt.contains("Existing review comments"))
        XCTAssertTrue(bundle.userPrompt.contains("@alice"))
        XCTAssertTrue(bundle.userPrompt.contains("lgtm"))
    }

    func testCIStatusIconsMatchState() throws {
        let pr = makePR(checks: [
            CheckSummary(typename: "CheckRun", name: "build",  conclusion: "SUCCESS", status: "COMPLETED", url: nil),
            CheckSummary(typename: "CheckRun", name: "lint",   conclusion: "FAILURE", status: "COMPLETED", url: nil),
            CheckSummary(typename: "CheckRun", name: "deploy", conclusion: nil,        status: "IN_PROGRESS", url: nil),
        ])
        let bundle = try ContextAssembler.assemble(
            pr: pr, subdiff: subdiff(), diffText: "<>",
            toolMode: .none, workdir: URL(fileURLWithPath: "/tmp")
        )
        XCTAssertTrue(bundle.userPrompt.contains("✓ `build`"))
        XCTAssertTrue(bundle.userPrompt.contains("✗ `lint`"))
        XCTAssertTrue(bundle.userPrompt.contains("⏳ `deploy`"))
    }

    func testCIFailuresIncludedAfterStatus() throws {
        let bundle = try ContextAssembler.assemble(
            pr: makePR(),
            subdiff: subdiff(),
            diffText: "<>",
            ciFailures: [
                CIFailureLog(jobName: "test-billing", logTail: "FAIL: TestFoo\n  expected x got y"),
            ],
            toolMode: .none,
            workdir: URL(fileURLWithPath: "/tmp")
        )
        XCTAssertTrue(bundle.userPrompt.contains("CI failures"))
        XCTAssertTrue(bundle.userPrompt.contains("test-billing"))
        XCTAssertTrue(bundle.userPrompt.contains("FAIL: TestFoo"))
    }

    func testDiffSectionIsLast() throws {
        let bundle = try ContextAssembler.assemble(
            pr: makePR(),
            subdiff: subdiff(),
            diffText: "diff --git a/a b/a\n@@ -1 +1 @@\n-old\n+new\n",
            toolMode: .none,
            workdir: URL(fileURLWithPath: "/tmp")
        )
        let promptIndex = bundle.userPrompt.range(of: "## Diff")!
        // No headings should appear after the Diff section.
        let afterDiff = bundle.userPrompt[promptIndex.upperBound...]
        XCTAssertFalse(afterDiff.contains("\n##"))
    }

    func testLanguageOverrideAppliedToSystemPrompt() throws {
        let goSubdiff = Subdiff(
            subpath: "kernel-billing",
            hunks: [Hunk(filePath: "kernel-billing/log.go", oldStart: 1, oldCount: 0, newStart: 1, newCount: 1,
                         lines: [.added("// new")])]
        )
        let bundle = try ContextAssembler.assemble(
            pr: makePR(), subdiff: goSubdiff, diffText: "<>",
            toolMode: .minimal, workdir: URL(fileURLWithPath: "/tmp")
        )
        // Go override mentions goroutine leaks. Base prompt does not.
        XCTAssertTrue(bundle.systemPrompt.contains("Goroutine leaks"))
    }

    func testPriorReviewsSectionRendersWhenProvided() throws {
        let priors: [PriorReview] = [
            PriorReview(
                headSha: "olds1234567",
                aggregated: AggregatedReview(
                    verdict: .comment,
                    confidence: 0.6,
                    summaryMarkdown: "Some early concern",
                    annotations: [],
                    costUsd: 0.01,
                    toolCallCount: 0,
                    toolNamesUsed: [],
                    perSubreview: [],
                    isSubscriptionAuth: true
                )
            ),
            PriorReview(
                headSha: "olds7654321",
                aggregated: AggregatedReview(
                    verdict: .requestChanges,
                    confidence: 0.82,
                    summaryMarkdown: "Watch the goroutine leak in worker.go",
                    annotations: [
                        DiffAnnotation(
                            path: "worker.go",
                            lineStart: 42, lineEnd: 42,
                            severity: .blocker,
                            title: "Goroutine leaks on error path",
                            body: "..."
                        )
                    ],
                    costUsd: 0.04,
                    toolCallCount: 2,
                    toolNamesUsed: ["Read"],
                    perSubreview: [],
                    isSubscriptionAuth: true
                )
            )
        ]
        let bundle = try ContextAssembler.assemble(
            pr: makePR(), subdiff: subdiff(), diffText: "<>",
            toolMode: .none,
            workdir: URL(fileURLWithPath: "/tmp"),
            priorReviews: priors
        )
        XCTAssertTrue(bundle.userPrompt.contains("Earlier internal review drafts"))
        XCTAssertTrue(bundle.userPrompt.contains("NOT posted to GitHub"),
            "framing must make clear the drafts were never sent")
        XCTAssertTrue(bundle.userPrompt.contains("Draft 1 — commit `olds123"))
        XCTAssertTrue(bundle.userPrompt.contains("Draft 2 — commit `olds765"))
        XCTAssertTrue(bundle.userPrompt.contains("`request_changes`"),
            "should mention prior verdicts")
        XCTAssertTrue(bundle.userPrompt.contains("Goroutine leaks on error path"),
            "should list prior blocking annotations as memory aid")
        XCTAssertTrue(bundle.userPrompt.contains("one consolidated final review"),
            "should instruct the model to produce a single fresh final review")
    }

    func testPriorReviewsSectionAbsentWhenEmpty() throws {
        let bundle = try ContextAssembler.assemble(
            pr: makePR(), subdiff: subdiff(), diffText: "<>",
            toolMode: .none, workdir: URL(fileURLWithPath: "/tmp")
        )
        XCTAssertFalse(bundle.userPrompt.contains("Earlier internal review drafts"))
    }

    // MARK: helpers

    private func makePR(checks: [CheckSummary] = []) -> InboxPR {
        InboxPR(
            nodeId: "PR_1",
            owner: "getsynq", repo: "cloud", number: 4821,
            title: "feat: audit log",
            body: "## Summary\nAdds audit log to billing.",
            url: URL(string: "https://github.com/getsynq/cloud/pull/4821")!,
            author: "alice",
            headRef: "feat/audit", baseRef: "main",
            headSha: "abc123",
            isDraft: false,
            role: .reviewRequested,
            mergeable: "MERGEABLE", mergeStateStatus: "BLOCKED",
            reviewDecision: "REVIEW_REQUIRED",
            checkRollupState: "PENDING",
            totalAdditions: 312, totalDeletions: 47, changedFiles: 8,
            hasAutoMerge: false, autoMergeEnabledBy: nil,
            allCheckSummaries: checks,
            allowedMergeMethods: [.squash, .rebase],
            autoMergeAllowed: true, deleteBranchOnMerge: true
        )
    }

    private func subdiff(subpath: String = "kernel-billing") -> Subdiff {
        Subdiff(
            subpath: subpath,
            hunks: [
                Hunk(filePath: "\(subpath)/file.go", oldStart: 1, oldCount: 1, newStart: 1, newCount: 2,
                     lines: [.context("a"), .added("b")])
            ]
        )
    }
}
