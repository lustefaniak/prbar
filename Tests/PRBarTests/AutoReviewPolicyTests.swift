import XCTest
@testable import PRBar

final class AutoReviewPolicyTests: XCTestCase {
    private let onApprove = AutoApproveConfig(
        enabled: true,
        minConfidence: 0.85,
        maxAnnotationSeverity: .suggestion,
        maxAdditions: 200
    )

    private func config(
        approve: AutoApproveConfig? = nil,
        deny: AutoDenyConfig = .off,
        share: ShareFindingsPolicy = .off
    ) -> RepoConfig {
        var cfg = RepoConfig.default
        cfg.autoApprove = approve ?? onApprove
        cfg.autoDeny = deny
        cfg.shareFindings = share
        return cfg
    }

    // MARK: - share side

    private let warning = DiffAnnotation(
        path: "a", lineStart: 1, lineEnd: 1, severity: .warning,
        title: "Unchecked nil", body: "this can crash"
    )
    private let nit = DiffAnnotation(
        path: "a", lineStart: 2, lineEnd: 2, severity: .info,
        title: "Nit", body: "rename this"
    )

    func testShareOffLeavesTheSkipIntact() {
        let result = evaluate(
            pr: makePR(additions: 10),
            review: makeReview(verdict: .approve, confidence: 0.10, annotations: [warning]),
            config: config(share: .off)
        )
        guard case .skip = result else { return XCTFail("expected skip, got \(result)") }
    }

    func testShareFiresWhenBothAutoSidesSkip() {
        let result = evaluate(
            pr: makePR(additions: 10),
            // Confidence below the approve floor, so the approve side skips.
            review: makeReview(verdict: .approve, confidence: 0.10, annotations: [warning]),
            config: config(share: .warningsAndBlockers)
        )
        XCTAssertEqual(result, .share)
    }

    func testShareRespectsItsSeverityFloor() {
        let review = makeReview(verdict: .approve, confidence: 0.10, annotations: [nit])
        guard case .skip = evaluate(
            pr: makePR(additions: 10), review: review,
            config: config(share: .warningsAndBlockers)
        ) else { return XCTFail("an info annotation must not clear the warnings floor") }

        XCTAssertEqual(
            evaluate(pr: makePR(additions: 10), review: review, config: config(share: .allFindings)),
            .share
        )
    }

    func testShareNeedsSomethingToSay() {
        let result = evaluate(
            pr: makePR(additions: 10),
            review: makeReview(verdict: .approve, confidence: 0.10, annotations: []),
            config: config(share: .allFindings)
        )
        guard case .skip = result else {
            return XCTFail("a summary with no findings gives the author nothing to act on")
        }
    }

    /// Share is a fallback for the skip path only — it must never divert a
    /// decision the user armed the auto gates to make.
    func testShareNeverPreemptsAFiringAutoSide() {
        XCTAssertEqual(
            evaluate(
                pr: makePR(additions: 10),
                review: makeReview(verdict: .approve, confidence: 0.99, annotations: [nit]),
                config: config(share: .allFindings)
            ),
            .approve
        )
        XCTAssertEqual(
            evaluate(
                pr: makePR(additions: 10),
                review: makeReview(verdict: .requestChanges, confidence: 0.99, annotations: [warning]),
                config: config(deny: AutoDenyConfig(action: .requestChanges), share: .allFindings)
            ),
            .deny(.requestChanges)
        )
    }

    // MARK: - approve side

    func testDisabledShortCircuits() {
        let result = evaluate(
            pr: makePR(additions: 10),
            review: makeReview(verdict: .approve, confidence: 0.99),
            config: config(approve: .off)
        )
        XCTAssertEqual(result, .skip(reason: "auto-approve disabled for this repo"))
    }

    func testApproveWithNotesSkippedByDefault() {
        let result = evaluate(
            pr: makePR(additions: 10),
            review: makeReview(verdict: .comment, confidence: 0.99),
            config: config()
        )
        if case .skip(let reason) = result {
            XCTAssertTrue(reason.contains("Approve with notes"), "got reason: \(reason)")
        } else {
            XCTFail("expected skip")
        }
    }

    func testApproveWithNotesApprovesWhenAllowed() {
        var cfg = onApprove
        cfg.allowApproveWithNotes = true
        let result = evaluate(
            pr: makePR(additions: 10),
            review: makeReview(verdict: .comment, confidence: 0.99),
            config: config(approve: cfg)
        )
        XCTAssertEqual(result, .approve)
    }

    func testLowConfidenceSkipped() {
        let result = evaluate(
            pr: makePR(additions: 10),
            review: makeReview(verdict: .approve, confidence: 0.7),
            config: config()
        )
        if case .skip(let reason) = result {
            XCTAssertTrue(reason.contains("confidence"))
        } else {
            XCTFail("expected skip")
        }
    }

    /// A provider-specific floor overrides the shared one only for that
    /// provider — the whole point of splitting them.
    func testPerProviderConfidenceFloor() {
        var cfg = onApprove
        cfg.codexMinConfidence = 0.95
        let review = makeReview(verdict: .approve, confidence: 0.90)

        XCTAssertEqual(
            evaluate(pr: makePR(additions: 10), review: review,
                     providerId: .claude, config: config(approve: cfg)),
            .approve
        )
        if case .skip(let reason) = evaluate(
            pr: makePR(additions: 10), review: review,
            providerId: .codex, config: config(approve: cfg)
        ) {
            XCTAssertTrue(reason.contains("Codex"), "got reason: \(reason)")
        } else {
            XCTFail("expected skip for codex")
        }
    }

    func testBlockingAnnotationSkipped() {
        let result = evaluate(
            pr: makePR(additions: 10),
            review: makeReview(verdict: .approve, confidence: 0.99,
                               annotations: [makeAnnotation(severity: .blocker)]),
            config: config()
        )
        if case .skip(let reason) = result {
            XCTAssertTrue(reason.contains("Suggestion"), "got reason: \(reason)")
        } else {
            XCTFail("expected skip")
        }
    }

    func testInfoAnnotationDoesNotBlock() {
        let result = evaluate(
            pr: makePR(additions: 10),
            review: makeReview(verdict: .approve, confidence: 0.99,
                               annotations: [makeAnnotation(severity: .info)]),
            config: config()
        )
        XCTAssertEqual(result, .approve)
    }

    func testRaisedSeverityCeilingTolerates() {
        var cfg = onApprove
        cfg.maxAnnotationSeverity = .warning
        let result = evaluate(
            pr: makePR(additions: 10),
            review: makeReview(verdict: .approve, confidence: 0.99,
                               annotations: [makeAnnotation(severity: .warning)]),
            config: config(approve: cfg)
        )
        XCTAssertEqual(result, .approve)
    }

    func testAnnotationCountCap() {
        var cfg = onApprove
        cfg.maxAnnotations = 2
        let result = evaluate(
            pr: makePR(additions: 10),
            review: makeReview(verdict: .approve, confidence: 0.99,
                               annotations: Array(repeating: makeAnnotation(severity: .info), count: 3)),
            config: config(approve: cfg)
        )
        if case .skip(let reason) = result {
            XCTAssertTrue(reason.contains("3 annotations"), "got reason: \(reason)")
        } else {
            XCTFail("expected skip")
        }
    }

    func testTooBigSkipped() {
        let result = evaluate(
            pr: makePR(additions: 5000),
            review: makeReview(verdict: .approve, confidence: 0.99),
            config: config()
        )
        if case .skip(let reason) = result {
            XCTAssertTrue(reason.contains("5000"))
        } else {
            XCTFail("expected skip")
        }
    }

    func testDeletionAndFileCaps() {
        var cfg = onApprove
        cfg.maxDeletions = 50
        cfg.maxChangedFiles = 3
        let review = makeReview(verdict: .approve, confidence: 0.99)

        if case .skip(let reason) = evaluate(
            pr: makePR(additions: 10, deletions: 500), review: review,
            config: config(approve: cfg)
        ) {
            XCTAssertTrue(reason.contains("-500"), "got reason: \(reason)")
        } else {
            XCTFail("expected skip on deletions")
        }

        if case .skip(let reason) = evaluate(
            pr: makePR(additions: 10, changedFiles: 20), review: review,
            config: config(approve: cfg)
        ) {
            XCTAssertTrue(reason.contains("20 files"), "got reason: \(reason)")
        } else {
            XCTFail("expected skip on changed files")
        }
    }

    func testZeroCapsMeanUnlimited() {
        var cfg = onApprove
        cfg.maxAdditions = 0
        let result = evaluate(
            pr: makePR(additions: 100_000, deletions: 100_000, changedFiles: 900),
            review: makeReview(verdict: .approve, confidence: 0.99),
            config: config(approve: cfg)
        )
        XCTAssertEqual(result, .approve)
    }

    func testHappyPathApproves() {
        let result = evaluate(
            pr: makePR(additions: 10),
            review: makeReview(verdict: .approve, confidence: 0.99),
            config: config()
        )
        XCTAssertEqual(result, .approve)
    }

    func testAbstainNeverActs() {
        let result = evaluate(
            pr: makePR(additions: 10),
            review: makeReview(verdict: .abstain, confidence: 0.99),
            config: config(deny: AutoDenyConfig(action: .requestChanges))
        )
        XCTAssertEqual(result, .skip(reason: "AI abstained"))
    }

    // MARK: - deny side

    func testDenyOffByDefault() {
        let result = evaluate(
            pr: makePR(additions: 10),
            review: makeReview(verdict: .requestChanges, confidence: 0.99,
                               annotations: [makeAnnotation(severity: .blocker)]),
            config: config()
        )
        XCTAssertEqual(result, .skip(reason: "auto-deny disabled for this repo"))
    }

    func testDenyFiresWhenGatesPass() {
        let result = evaluate(
            pr: makePR(additions: 10),
            review: makeReview(verdict: .requestChanges, confidence: 0.99,
                               annotations: [makeAnnotation(severity: .blocker)]),
            config: config(deny: AutoDenyConfig(action: .requestChanges))
        )
        XCTAssertEqual(result, .deny(.requestChanges))
    }

    func testDenyCarriesConfiguredAction() {
        for action in [AutoDenyAction.flagOnly, .comment, .requestChanges] {
            let result = evaluate(
                pr: makePR(additions: 10),
                review: makeReview(verdict: .requestChanges, confidence: 0.99,
                                   annotations: [makeAnnotation(severity: .warning)]),
                config: config(deny: AutoDenyConfig(action: action))
            )
            XCTAssertEqual(result, .deny(action), "action \(action.rawValue)")
        }
    }

    /// A negative verdict with nothing line-level to point at is the case
    /// most likely to be wrong and the least actionable if it isn't.
    func testDenyNeedsCorroboratingAnnotations() {
        let result = evaluate(
            pr: makePR(additions: 10),
            review: makeReview(verdict: .requestChanges, confidence: 0.99,
                               annotations: [makeAnnotation(severity: .suggestion)]),
            config: config(deny: AutoDenyConfig(action: .requestChanges))
        )
        if case .skip(let reason) = result {
            XCTAssertTrue(reason.contains("need 1"), "got reason: \(reason)")
        } else {
            XCTFail("expected skip")
        }
    }

    func testDenyVerdictAloneWhenNoAnnotationsRequired() {
        let result = evaluate(
            pr: makePR(additions: 10),
            review: makeReview(verdict: .requestChanges, confidence: 0.99),
            config: config(deny: AutoDenyConfig(action: .comment, minMatchingAnnotations: 0))
        )
        XCTAssertEqual(result, .deny(.comment))
    }

    func testDenyHasItsOwnConfidenceFloor() {
        // Approve floor is 0.85; the deny floor is stricter here, so a
        // 0.90 review clears one gate and not the other.
        let deny = AutoDenyConfig(action: .requestChanges, minConfidence: 0.95)
        let result = evaluate(
            pr: makePR(additions: 10),
            review: makeReview(verdict: .requestChanges, confidence: 0.90,
                               annotations: [makeAnnotation(severity: .blocker)]),
            config: config(deny: deny)
        )
        if case .skip(let reason) = result {
            XCTAssertTrue(reason.contains("deny threshold"), "got reason: \(reason)")
        } else {
            XCTFail("expected skip")
        }
    }

    func testDenySkipsOversizedPRs() {
        let deny = AutoDenyConfig(action: .requestChanges, maxAdditions: 100)
        let result = evaluate(
            pr: makePR(additions: 5000),
            review: makeReview(verdict: .requestChanges, confidence: 0.99,
                               annotations: [makeAnnotation(severity: .blocker)]),
            config: config(deny: deny)
        )
        if case .skip(let reason) = result {
            XCTAssertTrue(reason.contains("5000"), "got reason: \(reason)")
        } else {
            XCTFail("expected skip")
        }
    }

    // MARK: - helpers

    private func evaluate(
        pr: InboxPR,
        review: AggregatedReview,
        providerId: ProviderID = .claude,
        config: RepoConfig
    ) -> AutoReviewPolicy.Decision {
        AutoReviewPolicy.evaluate(
            pr: pr, review: review, providerId: providerId, config: config.resolved()
        )
    }

    private func makePR(additions: Int, deletions: Int = 0, changedFiles: Int = 1) -> InboxPR {
        InboxPR(
            nodeId: "PR_1", owner: "o", repo: "r", number: 1,
            title: "t", body: "", url: URL(string: "https://github.com/o/r/pull/1")!,
            author: "a", headRef: "h", baseRef: "main",
            headSha: "abc123", isDraft: false,
            role: .reviewRequested,
            mergeable: "MERGEABLE", mergeStateStatus: "CLEAN", reviewDecision: nil,
            checkRollupState: "SUCCESS",
            totalAdditions: additions, totalDeletions: deletions, changedFiles: changedFiles,
            hasAutoMerge: false, autoMergeEnabledBy: nil, allCheckSummaries: [],
            allowedMergeMethods: [.squash], autoMergeAllowed: false, deleteBranchOnMerge: false
        )
    }

    private func makeReview(
        verdict: ReviewVerdict,
        confidence: Double,
        annotations: [DiffAnnotation] = []
    ) -> AggregatedReview {
        let result = ProviderResult(
            verdict: verdict,
            confidence: confidence,
            summaryMarkdown: "ok",
            annotations: annotations,
            costUsd: 0.01,
            toolCallCount: 0,
            toolNamesUsed: [],
            rawJson: Data()
        )
        return AggregatedReview(
            verdict: verdict,
            confidence: confidence,
            summaryMarkdown: "ok",
            annotations: annotations,
            costUsd: 0.01,
            toolCallCount: 0,
            toolNamesUsed: [],
            perSubreview: [SubreviewOutcome(subpath: "", result: result)],
            isSubscriptionAuth: false
        )
    }

    private func makeAnnotation(severity: AnnotationSeverity) -> DiffAnnotation {
        DiffAnnotation(path: "x.go", lineStart: 1, lineEnd: 1, severity: severity, body: "n")
    }
}
