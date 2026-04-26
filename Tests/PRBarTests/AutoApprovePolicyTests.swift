import XCTest
@testable import PRBar

final class AutoApprovePolicyTests: XCTestCase {
    private let onConfig = AutoApproveConfig(
        enabled: true,
        minConfidence: 0.85,
        requireZeroBlockingAnnotations: true,
        maxAdditions: 200
    )

    func testDisabledShortCircuits() {
        let result = AutoApprovePolicy.evaluate(
            pr: makePR(additions: 10),
            review: makeReview(verdict: .approve, confidence: 0.99),
            config: .off
        )
        XCTAssertEqual(result, .skip(reason: "auto-approve disabled for this repo"))
    }

    func testNonApproveVerdictSkipped() {
        let result = AutoApprovePolicy.evaluate(
            pr: makePR(additions: 10),
            review: makeReview(verdict: .comment, confidence: 0.99),
            config: onConfig
        )
        if case .skip(let reason) = result {
            XCTAssertTrue(reason.contains("Comment"))
        } else {
            XCTFail("expected skip")
        }
    }

    func testLowConfidenceSkipped() {
        let result = AutoApprovePolicy.evaluate(
            pr: makePR(additions: 10),
            review: makeReview(verdict: .approve, confidence: 0.7),
            config: onConfig
        )
        if case .skip(let reason) = result {
            XCTAssertTrue(reason.contains("confidence"))
        } else {
            XCTFail("expected skip")
        }
    }

    func testBlockingAnnotationSkipped() {
        let result = AutoApprovePolicy.evaluate(
            pr: makePR(additions: 10),
            review: makeReview(verdict: .approve, confidence: 0.99,
                               annotations: [makeAnnotation(severity: .blocker)]),
            config: onConfig
        )
        if case .skip(let reason) = result {
            XCTAssertTrue(reason.contains("blocking"))
        } else {
            XCTFail("expected skip")
        }
    }

    func testInfoAnnotationDoesNotBlock() {
        let result = AutoApprovePolicy.evaluate(
            pr: makePR(additions: 10),
            review: makeReview(verdict: .approve, confidence: 0.99,
                               annotations: [makeAnnotation(severity: .info)]),
            config: onConfig
        )
        XCTAssertEqual(result, .approve)
    }

    func testTooBigSkipped() {
        let result = AutoApprovePolicy.evaluate(
            pr: makePR(additions: 5000),
            review: makeReview(verdict: .approve, confidence: 0.99),
            config: onConfig
        )
        if case .skip(let reason) = result {
            XCTAssertTrue(reason.contains("5000"))
        } else {
            XCTFail("expected skip")
        }
    }

    func testZeroMaxAdditionsMeansUnlimited() {
        var cfg = onConfig
        cfg.maxAdditions = 0
        let result = AutoApprovePolicy.evaluate(
            pr: makePR(additions: 100_000),
            review: makeReview(verdict: .approve, confidence: 0.99),
            config: cfg
        )
        XCTAssertEqual(result, .approve)
    }

    func testHappyPathApproves() {
        let result = AutoApprovePolicy.evaluate(
            pr: makePR(additions: 10),
            review: makeReview(verdict: .approve, confidence: 0.99),
            config: onConfig
        )
        XCTAssertEqual(result, .approve)
    }

    // MARK: - helpers

    private func makePR(additions: Int) -> InboxPR {
        InboxPR(
            nodeId: "PR_1", owner: "o", repo: "r", number: 1,
            title: "t", body: "", url: URL(string: "https://github.com/o/r/pull/1")!,
            author: "a", headRef: "h", baseRef: "main",
            headSha: "abc123", isDraft: false,
            role: .reviewRequested,
            mergeable: "MERGEABLE", mergeStateStatus: "CLEAN", reviewDecision: nil,
            checkRollupState: "SUCCESS",
            totalAdditions: additions, totalDeletions: 0, changedFiles: 1,
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
