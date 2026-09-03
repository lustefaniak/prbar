import XCTest
@testable import PRBar

@MainActor
final class RepoConfigFilterTests: XCTestCase {

    // MARK: - PRPoller title-exclude filter

    func testPollerDropsTitleMatchedPRs() async throws {
        let resolver: @Sendable (String, String) -> ResolvedRepoConfig = { _, _ in
            var c = RepoConfig.default
            c.excludeTitlePatterns = ["[Prod deploy]*", "*chore: bump*"]
            return c.resolved()
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
        let resolver: @Sendable (String, String) -> ResolvedRepoConfig = { _, _ in
            var c = RepoConfig.default
            c.excludeTitlePatterns = ["RELEASE/*"]
            return c.resolved()
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
        let resolver: @Sendable (String, String) -> ResolvedRepoConfig = { _, _ in
            RepoConfig.default.resolved()
        }
        let prs = [makePR(nodeId: "P1", title: "anything")]
        let poller = PRPoller(fetcher: { prs })
        poller.configResolver = resolver
        poller.pollNow()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(poller.prs.count, 1)
    }

    // MARK: - isReviewedByOthers predicate

    func testIsReviewedByOthers() {
        XCTAssertTrue(makePR(reviewDecision: "APPROVED").isReviewedByOthers)
        XCTAssertTrue(makePR(reviewDecision: "CHANGES_REQUESTED").isReviewedByOthers)
        XCTAssertFalse(makePR(reviewDecision: "REVIEW_REQUIRED").isReviewedByOthers)
        XCTAssertFalse(makePR(reviewDecision: nil).isReviewedByOthers)
    }

    func testChangesRequestedStaysHandledWhileFlaggedCodeIsCurrent() {
        let reviewedAt = Date(timeIntervalSince1970: 2_000)
        let committedBefore = Date(timeIntervalSince1970: 1_000)
        let pr = makePR(
            reviewDecision: "CHANGES_REQUESTED",
            headCommittedAt: committedBefore,
            humanReviews: [changeRequest(at: reviewedAt)]
        )
        // Head commit predates the change-request → not addressed yet → handled.
        XCTAssertTrue(pr.isReviewedByOthers)
    }

    func testChangesRequestedResurfacesAfterCommitPastReview() {
        let reviewedAt = Date(timeIntervalSince1970: 1_000)
        let committedAfter = Date(timeIntervalSince1970: 2_000)
        let pr = makePR(
            reviewDecision: "CHANGES_REQUESTED",
            headCommittedAt: committedAfter,
            humanReviews: [changeRequest(at: reviewedAt)]
        )
        // Author committed past the change-request → likely addressed → resurface.
        XCTAssertFalse(pr.isReviewedByOthers)
    }

    func testApprovedIgnoresCommitStaleness() {
        let pr = makePR(
            reviewDecision: "APPROVED",
            headCommittedAt: Date(timeIntervalSince1970: 9_999),
            humanReviews: [PRReviewSummary(author: "bob", state: "APPROVED",
                                           submittedAt: Date(timeIntervalSince1970: 1),
                                           body: "", isFromViewer: false)]
        )
        // A sign-off stays "handled" regardless of later commits.
        XCTAssertTrue(pr.isReviewedByOthers)
    }

    func testChangesRequestedWithoutTimestampsStaysHandled() {
        // No head-commit date / no review timestamps (old cache, fixtures) →
        // conservative default keeps prior behavior (treated as handled).
        XCTAssertTrue(makePR(reviewDecision: "CHANGES_REQUESTED").isReviewedByOthers)
    }

    func testChangesRequestedUsesLatestChangeRequest() {
        let early = Date(timeIntervalSince1970: 1_000)
        let late = Date(timeIntervalSince1970: 3_000)
        let between = Date(timeIntervalSince1970: 2_000)
        // Two reviewers flagged it; head landed between the two flags. The
        // newest flag (late) postdates the head → still unaddressed → handled.
        let pr = makePR(
            reviewDecision: "CHANGES_REQUESTED",
            headCommittedAt: between,
            humanReviews: [changeRequest(at: early, from: "alice"),
                           changeRequest(at: late, from: "bob")]
        )
        XCTAssertTrue(pr.isReviewedByOthers)
    }

    func testChangesRequestedEqualTimestampStaysHandled() {
        let t = Date(timeIntervalSince1970: 1_000)
        // Head committed exactly at the change-request time is the flagged
        // commit itself, not a fix → handled.
        let pr = makePR(
            reviewDecision: "CHANGES_REQUESTED",
            headCommittedAt: t,
            humanReviews: [changeRequest(at: t)]
        )
        XCTAssertTrue(pr.isReviewedByOthers)
    }

    func testChangesRequestedIgnoresNonChangeRequestReviews() {
        let flaggedAt = Date(timeIntervalSince1970: 1_000)
        let approvedLater = Date(timeIntervalSince1970: 5_000)
        let committedAfterFlag = Date(timeIntervalSince1970: 2_000)
        // A later APPROVED review must not raise the bar — only CHANGES_REQUESTED
        // timestamps count. Head postdates the lone change-request → resurface.
        let pr = makePR(
            reviewDecision: "CHANGES_REQUESTED",
            headCommittedAt: committedAfterFlag,
            humanReviews: [
                changeRequest(at: flaggedAt),
                PRReviewSummary(author: "carol", state: "APPROVED",
                                submittedAt: approvedLater, body: "", isFromViewer: false),
            ]
        )
        XCTAssertFalse(pr.isReviewedByOthers)
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
            claudeMinConfidence: 0.90, codexMinConfidence: 0.98,
            allowApproveWithNotes: true,
            maxAnnotationSeverity: .warning, maxAnnotations: 5,
            maxAdditions: 100, maxDeletions: 200, maxChangedFiles: 12,
            postAttributionComment: true, postInlineAnnotations: true
        )
        cfg.autoDeny = AutoDenyConfig(
            action: .requestChanges, minConfidence: 0.92,
            claudeMinConfidence: 0.93, codexMinConfidence: 0.94,
            requiredSeverity: .blocker, minMatchingAnnotations: 2,
            maxAdditions: 300, postInlineAnnotations: false
        )
        cfg.reviewDrafts = true
        cfg.excludeTitlePatterns = ["[Prod deploy]*"]
        cfg.skipAIIfReviewedByOthers = true
        cfg.aiReviewEnabled = false
        cfg.providerOverride = .codex
        cfg.notifyPolicy = .eachReady
        cfg.skipMergeConfirmation = true

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
        let rule = try JSONDecoder().decode(RepoConfig.self, from: Data(oldJSON.utf8))
        let cfg = rule.resolved()
        XCTAssertEqual(cfg.repoGlobs, ["acme/x"])
        XCTAssertEqual(cfg.excludeTitlePatterns, [])
        // Fields absent from a payload written before they existed are
        // not overrides — they inherit from ReviewDefaults, which is what
        // an unconfigured repo would get anyway.
        XCTAssertNil(rule.skipAIIfReviewedByOthers)
        XCTAssertTrue(cfg.skipAIIfReviewedByOthers)
        XCTAssertTrue(cfg.aiReviewEnabled)
        // Fields the payload *does* carry stay explicit overrides, so a
        // rule the user already tuned keeps behaving as it did.
        XCTAssertEqual(rule.maxCostUsdPerSubreview, 0.30)
        XCTAssertEqual(cfg.maxCostUsdPerSubreview, 0.30)
        // Per-repo merge-confirmation override absent in old payloads →
        // nil = follow the global setting.
        XCTAssertNil(cfg.skipMergeConfirmation)
        // Auto-deny postdates these payloads and must stay off — a
        // migration that silently enabled it would have PRBar posting
        // "changes requested" on repos the user never opted in.
        XCTAssertEqual(cfg.autoDeny.action, .off)
    }

    /// The severity ceiling replaced a boolean. Payloads written before
    /// the swap must keep meaning what they meant: "no blocking
    /// annotations" == tolerate nothing above `.suggestion`.
    func testAutoApproveMigratesLegacyBlockingAnnotationFlag() throws {
        let strict = """
        {"enabled": true, "minConfidence": 0.9, "requireZeroBlockingAnnotations": true, "maxAdditions": 200}
        """
        let lenient = """
        {"enabled": true, "minConfidence": 0.9, "requireZeroBlockingAnnotations": false, "maxAdditions": 200}
        """
        let decodedStrict = try JSONDecoder().decode(AutoApproveConfig.self, from: Data(strict.utf8))
        let decodedLenient = try JSONDecoder().decode(AutoApproveConfig.self, from: Data(lenient.utf8))

        XCTAssertEqual(decodedStrict.maxAnnotationSeverity, .suggestion)
        XCTAssertEqual(decodedLenient.maxAnnotationSeverity, .blocker)
        // Both predate the posting flags, which must default to off so an
        // upgrade stops the attribution comments rather than continuing them.
        XCTAssertFalse(decodedStrict.postAttributionComment)
        XCTAssertFalse(decodedStrict.postInlineAnnotations)
        XCTAssertFalse(decodedStrict.allowApproveWithNotes)
    }

    // MARK: - helpers

    private func makePR(
        nodeId: String = "PR_1",
        title: String = "title",
        reviewDecision: String? = nil,
        headCommittedAt: Date? = nil,
        humanReviews: [PRReviewSummary] = []
    ) -> InboxPR {
        var pr = InboxPR(
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
        pr.headCommittedAt = headCommittedAt
        pr.humanReviews = humanReviews
        return pr
    }

    private func changeRequest(at submittedAt: Date, from author: String = "bob") -> PRReviewSummary {
        PRReviewSummary(
            author: author, state: "CHANGES_REQUESTED",
            submittedAt: submittedAt, body: "please fix", isFromViewer: false
        )
    }
}
