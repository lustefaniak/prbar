import XCTest
@testable import PRBar

final class ResultAggregatorTests: XCTestCase {
    func testEmptyInputReturnsNil() {
        XCTAssertNil(ResultAggregator.aggregate([]))
    }

    func testSingleSubreviewPassThrough() {
        let r = makeResult(verdict: .approve, confidence: 0.9, summary: "ok")
        let agg = ResultAggregator.aggregate([
            SubreviewOutcome(subpath: "", result: r)
        ])
        XCTAssertEqual(agg?.verdict, .approve)
        XCTAssertEqual(agg?.confidence ?? 0, 0.9, accuracy: 1e-9)
        XCTAssertEqual(agg?.summaryMarkdown, "ok",
            "single-subreview summary should be the result's summary, no header")
    }

    func testWorstVerdictAcrossSubreviews() {
        let outcomes = [
            SubreviewOutcome(subpath: "a", result: makeResult(verdict: .approve)),
            SubreviewOutcome(subpath: "b", result: makeResult(verdict: .comment)),
            SubreviewOutcome(subpath: "c", result: makeResult(verdict: .requestChanges)),
        ]
        XCTAssertEqual(ResultAggregator.aggregate(outcomes)?.verdict, .requestChanges)
    }

    func testApproveBeatsAbstain() {
        let outcomes = [
            SubreviewOutcome(subpath: "a", result: makeResult(verdict: .approve, confidence: 0.7)),
            SubreviewOutcome(subpath: "b", result: makeResult(verdict: .abstain, confidence: 0.0)),
        ]
        let agg = ResultAggregator.aggregate(outcomes)!
        XCTAssertEqual(agg.verdict, .approve)
        // Confidence min should ignore the abstain (its confidence is meaningless).
        XCTAssertEqual(agg.confidence, 0.7, accuracy: 1e-9)
    }

    func testMinConfidenceUsedWhenAllNonAbstain() {
        let outcomes = [
            SubreviewOutcome(subpath: "a", result: makeResult(verdict: .approve, confidence: 0.9)),
            SubreviewOutcome(subpath: "b", result: makeResult(verdict: .comment, confidence: 0.5)),
        ]
        XCTAssertEqual(ResultAggregator.aggregate(outcomes)?.confidence ?? 0, 0.5, accuracy: 1e-9)
    }

    func testSummaryConcatenatesWithHeadings() {
        let outcomes = [
            SubreviewOutcome(subpath: "kernel-billing", result: makeResult(verdict: .comment, summary: "billing notes")),
            SubreviewOutcome(subpath: "lib/auth",       result: makeResult(verdict: .approve, summary: "auth ok")),
        ]
        let s = ResultAggregator.aggregate(outcomes)!.summaryMarkdown
        XCTAssertTrue(s.contains("`kernel-billing`"))
        XCTAssertTrue(s.contains("`lib/auth`"))
        XCTAssertTrue(s.contains("billing notes"))
        XCTAssertTrue(s.contains("auth ok"))
    }

    func testAnnotationPathsRewrittenWithSubpathPrefix() {
        let outcomes = [
            SubreviewOutcome(subpath: "kernel-billing", result: makeResult(annotations: [
                DiffAnnotation(path: "audit/log.go",         lineStart: 5, lineEnd: 5, severity: .warning, body: "x"),
                DiffAnnotation(path: "kernel-billing/api.go", lineStart: 3, lineEnd: 3, severity: .info,    body: "y"),
            ])),
            SubreviewOutcome(subpath: "", result: makeResult(annotations: [
                DiffAnnotation(path: "README.md", lineStart: 1, lineEnd: 1, severity: .suggestion, body: "z"),
            ])),
        ]
        let merged = ResultAggregator.aggregate(outcomes)!.annotations
        XCTAssertEqual(merged.map(\.path), [
            "kernel-billing/audit/log.go",       // prefixed
            "kernel-billing/api.go",             // already prefixed — left alone
            "README.md",                         // empty subpath, no rewrite
        ])
    }

    func testCostAndToolCountsSum() {
        let outcomes = [
            SubreviewOutcome(subpath: "a", result: makeResult(costUsd: 0.05, toolCallCount: 2, toolNames: ["Read", "Grep"])),
            SubreviewOutcome(subpath: "b", result: makeResult(costUsd: 0.10, toolCallCount: 3, toolNames: ["Read", "WebFetch"])),
        ]
        let agg = ResultAggregator.aggregate(outcomes)!
        XCTAssertEqual(agg.costUsd, 0.15, accuracy: 1e-9)
        XCTAssertEqual(agg.toolCallCount, 5)
        XCTAssertEqual(agg.toolNamesUsed, ["Read", "Grep", "WebFetch"])
    }

    // MARK: helpers

    private func makeResult(
        verdict: ReviewVerdict = .approve,
        confidence: Double = 0.8,
        summary: String = "summary",
        annotations: [DiffAnnotation] = [],
        costUsd: Double = 0.05,
        toolCallCount: Int = 0,
        toolNames: [String] = []
    ) -> ProviderResult {
        ProviderResult(
            verdict: verdict,
            confidence: confidence,
            summaryMarkdown: summary,
            annotations: annotations,
            costUsd: costUsd,
            toolCallCount: toolCallCount,
            toolNamesUsed: toolNames,
            rawJson: Data()
        )
    }
}
