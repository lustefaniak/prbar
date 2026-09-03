import XCTest
@testable import PRBar

/// Regression net for the "test" reviews: claude did a thorough review but
/// the CLI's StructuredOutput tool corrupted the long summary (leaking the
/// annotations parameter into the summary string), the required-annotations
/// schema rejected it repeatedly, and the model degraded to a placeholder
/// `{"summary":"test"}` which got stored. These tests lock in that we
/// recover the substantive review instead.
final class StructuredOutputRecoveryTests: XCTestCase {
    // Shape of a real leaked attempt: a substantive summary whose tail
    // carries the escaped `</summary>` + `<parameter name="annotations">`
    // serialization noise, with the annotations JSON surviving after it.
    private let leakedSummary = """
    Clean port of the MS Teams composers onto the shared alert_templating engine. \
    I verified the duplicated-gating-logic risk between ownerScope and \
    MsTeamsOwnershipMentions is correctly mirrored. Nothing blocking found.\
    </summary>
    <parameter name="annotations">[{"path":"utils/msteams.go","line_start":13,"line_end":37,"severity":"info","title":"Gating mirrors adapter.go","body":"Verified."}]
    """

    func testSanitizeStripsSummaryCloseTag() {
        let out = StructuredOutputRecovery.sanitizeSummary(leakedSummary)
        XCTAssertTrue(out.hasSuffix("Nothing blocking found."))
        XCTAssertFalse(out.contains("</summary>"))
        XCTAssertFalse(out.contains("<parameter"))
    }

    func testSanitizeLeavesCleanSummaryUnchanged() {
        let clean = "Looks correct; the new guard covers the nil path."
        XCTAssertEqual(StructuredOutputRecovery.sanitizeSummary(clean), clean)
    }

    func testRecoverAnnotationsFromLeakedTail() {
        let anns = StructuredOutputRecovery.recoverAnnotations(fromLeakedSummary: leakedSummary)
        XCTAssertEqual(anns.count, 1)
        XCTAssertEqual(anns.first?.path, "utils/msteams.go")
        XCTAssertEqual(anns.first?.lineStart, 13)
        XCTAssertEqual(anns.first?.severity, .info)
    }

    func testDecodeLenientCleansSummaryAndRecoversAnnotations() throws {
        // A leaked attempt has verdict + confidence + summary but NO
        // top-level annotations key (it leaked into the summary).
        let attempt = try JSONSerialization.data(withJSONObject: [
            "verdict": "comment",
            "confidence": 0.8,
            "summary": leakedSummary,
        ])
        let decoded = try XCTUnwrap(StructuredOutputRecovery.decodeLenient(attempt))
        XCTAssertEqual(decoded.verdict, .comment)
        XCTAssertTrue(decoded.summary.hasSuffix("Nothing blocking found."))
        XCTAssertEqual(decoded.annotations.count, 1)
    }

    func testBestFallsBackFromPlaceholderToRichestAttempt() throws {
        // The exact failure: final answer is the "test" placeholder, but a
        // rich (leaked) attempt sits earlier in the stream.
        let finalPlaceholder = try JSONSerialization.data(withJSONObject: [
            "verdict": "approve", "confidence": 0.5, "summary": "test", "annotations": [],
        ])
        let richAttempt = try JSONSerialization.data(withJSONObject: [
            "verdict": "comment", "confidence": 0.8, "summary": leakedSummary,
        ])
        let best = try XCTUnwrap(
            StructuredOutputRecovery.best(final: finalPlaceholder, attempts: [richAttempt])
        )
        XCTAssertEqual(best.verdict, .comment, "must recover the real verdict, not the placeholder approve")
        XCTAssertTrue(best.summary.hasSuffix("Nothing blocking found."))
        XCTAssertEqual(best.annotations.count, 1)
    }

    func testBestKeepsGoodFinalOverEarlierAttempts() throws {
        let goodFinal = try JSONSerialization.data(withJSONObject: [
            "verdict": "request_changes", "confidence": 0.9,
            "summary": "The retry loop never resets the backoff, so a single failure permanently slows the queue.",
            "annotations": [],
        ])
        let earlierDraft = try JSONSerialization.data(withJSONObject: [
            "verdict": "comment", "confidence": 0.7, "summary": "Draft, still investigating the backoff path here.",
        ])
        let best = try XCTUnwrap(
            StructuredOutputRecovery.best(final: goodFinal, attempts: [earlierDraft])
        )
        XCTAssertEqual(best.verdict, .requestChanges, "a substantive final answer wins over earlier drafts")
    }

    func testBestReturnsNilWhenNothingDecodes() {
        XCTAssertNil(StructuredOutputRecovery.best(final: nil, attempts: []))
        XCTAssertNil(StructuredOutputRecovery.best(final: Data("garbage".utf8), attempts: []))
    }

    func testDegeneratePlaceholdersDetected() {
        XCTAssertTrue(StructuredOutputRecovery.isDegenerate("test"))
        XCTAssertTrue(StructuredOutputRecovery.isDegenerate("Test summary."))
        XCTAssertFalse(StructuredOutputRecovery.isDegenerate(
            "The new guard mishandles the empty-slice case and will panic on an unowned entity."
        ))
    }
}
