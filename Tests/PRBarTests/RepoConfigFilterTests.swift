import XCTest
@testable import PRBar

@MainActor
final class RepoConfigFilterTests: XCTestCase {

    // MARK: - PRPoller title-exclude filter

    func testPollerDropsTitleMatchedPRs() async throws {
        let resolver: @Sendable (String, String) -> RepoConfig = { _, _ in
            var c = RepoConfig.default
            c.excludeTitlePatterns = ["[Prod deploy]*", "*chore: bump*"]
            return c
        }
        let prs = [
            makePR(nodeId: "P1", title: "[Prod deploy] kernel-foo 2026-04-27"),
            makePR(nodeId: "P2", title: "Add idempotency to kernel-bar"),
            makePR(nodeId: "P3", title: "chore: bump golangci-lint"),
        ]
        let poller = PRPoller(fetcher: { prs })
        poller.configResolver = resolver
        poller.pollNow()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(poller.prs.map(\.nodeId), ["P2"])
    }

    func testPollerCaseInsensitiveTitleMatch() async throws {
        let resolver: @Sendable (String, String) -> RepoConfig = { _, _ in
            var c = RepoConfig.default
            c.excludeTitlePatterns = ["RELEASE/*"]
            return c
        }
        let prs = [
            makePR(nodeId: "P1", title: "release/v1.2.3 cut"),
            makePR(nodeId: "P2", title: "Other"),
        ]
        let poller = PRPoller(fetcher: { prs })
        poller.configResolver = resolver
        poller.pollNow()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(poller.prs.map(\.nodeId), ["P2"])
    }

    func testPollerKeepsAllWhenPatternsEmpty() async throws {
        let resolver: @Sendable (String, String) -> RepoConfig = { _, _ in .default }
        let prs = [makePR(nodeId: "P1", title: "anything")]
        let poller = PRPoller(fetcher: { prs })
        poller.configResolver = resolver
        poller.pollNow()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(poller.prs.count, 1)
    }

    // MARK: - alreadyReviewedByOthers helper

    func testAlreadyReviewedByOthers() {
        XCTAssertTrue(ReviewQueueWorker.alreadyReviewedByOthers(makePR(reviewDecision: "APPROVED")))
        XCTAssertTrue(ReviewQueueWorker.alreadyReviewedByOthers(makePR(reviewDecision: "CHANGES_REQUESTED")))
        XCTAssertFalse(ReviewQueueWorker.alreadyReviewedByOthers(makePR(reviewDecision: "REVIEW_REQUIRED")))
        XCTAssertFalse(ReviewQueueWorker.alreadyReviewedByOthers(makePR(reviewDecision: nil)))
    }

    // MARK: - Forward-compat Codable

    func testRepoConfigRoundtripsAllFields() throws {
        var cfg = RepoConfig.default
        cfg.repoGlobs = ["acme/cloud"]
        cfg.rootPatterns = ["kernel-*", "lib/*", "dev-infra"]
        cfg.unmatchedStrategy = .groupAsOther
        cfg.minFilesPerSubreview = 3
        cfg.maxParallelSubreviews = 4
        cfg.collapseAboveSubreviewCount = 8
        cfg.toolModeOverride = .minimal
        cfg.customSystemPrompt = "Be terse."
        cfg.replaceBaseSystemPrompt = true
        cfg.maxToolCallsPerSubreview = 12
        cfg.maxCostUsdPerSubreview = 0.5
        cfg.autoApprove = AutoApproveConfig(
            enabled: true, minConfidence: 0.95,
            requireZeroBlockingAnnotations: true, maxAdditions: 100
        )
        cfg.reviewDrafts = true
        cfg.excludeTitlePatterns = ["[Prod deploy]*"]
        cfg.skipAIIfReviewedByOthers = true
        cfg.aiReviewEnabled = false
        cfg.providerOverride = .codex
        cfg.notifyPolicy = .eachReady

        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(RepoConfig.self, from: data)

        XCTAssertEqual(decoded, cfg, "RepoConfig must round-trip every field — partial Codable could silently drop edits at save() time")
    }

    func testRepoConfigDecodesMissingNewFieldsAsDefaults() throws {
        // Simulates a stored payload from an older schema (no
        // excludeTitlePatterns / skipAIIfReviewedByOthers keys).
        let oldJSON = """
        {
          "repoGlobs": ["acme/x"],
          "splitMode": "perSubfolder",
          "rootPatterns": [],
          "unmatchedStrategy": "reviewAtRoot",
          "minFilesPerSubreview": 1,
          "maxParallelSubreviews": 1,
          "maxToolCallsPerSubreview": 10,
          "maxCostUsdPerSubreview": 0.30
        }
        """
        let cfg = try JSONDecoder().decode(RepoConfig.self, from: Data(oldJSON.utf8))
        XCTAssertEqual(cfg.repoGlobs, ["acme/x"])
        XCTAssertEqual(cfg.excludeTitlePatterns, [])
        XCTAssertFalse(cfg.skipAIIfReviewedByOthers)
        XCTAssertTrue(cfg.aiReviewEnabled)
    }

    // MARK: - helpers

    private func makePR(
        nodeId: String = "PR_1",
        title: String = "title",
        reviewDecision: String? = nil
    ) -> InboxPR {
        InboxPR(
            nodeId: nodeId, owner: "acme", repo: "infra", number: 1,
            title: title, body: "",
            url: URL(string: "https://example.com")!,
            author: "alice", headRef: "h", baseRef: "main",
            headSha: "abc", isDraft: false, role: .reviewRequested,
            mergeable: "MERGEABLE", mergeStateStatus: "CLEAN",
            reviewDecision: reviewDecision, checkRollupState: "SUCCESS",
            totalAdditions: 1, totalDeletions: 0, changedFiles: 1,
            hasAutoMerge: false, autoMergeEnabledBy: nil, allCheckSummaries: [],
            allowedMergeMethods: [.squash], autoMergeAllowed: false,
            deleteBranchOnMerge: false
        )
    }
}
