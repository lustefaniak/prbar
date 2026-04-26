import XCTest
@testable import PRBar

final class ReviewTypesTests: XCTestCase {
    func testReviewVerdictEncodesSnakeCase() throws {
        let json = try JSONEncoder().encode(ReviewVerdict.requestChanges)
        XCTAssertEqual(String(data: json, encoding: .utf8), "\"request_changes\"")
    }

    func testReviewVerdictDecodesSnakeCase() throws {
        let raw = Data("\"request_changes\"".utf8)
        let v = try JSONDecoder().decode(ReviewVerdict.self, from: raw)
        XCTAssertEqual(v, .requestChanges)
    }

    func testSeverityRankOrdering() {
        let sorted = [
            ReviewVerdict.requestChanges,
            .approve,
            .comment,
            .abstain,
        ].sorted { $0.severityRank < $1.severityRank }
        XCTAssertEqual(sorted, [.abstain, .approve, .comment, .requestChanges])
    }

    func testAnnotationSeverityIsBlocking() {
        XCTAssertFalse(AnnotationSeverity.info.isBlocking)
        XCTAssertFalse(AnnotationSeverity.suggestion.isBlocking)
        XCTAssertTrue(AnnotationSeverity.warning.isBlocking)
        XCTAssertTrue(AnnotationSeverity.blocker.isBlocking)
    }

    func testDiffAnnotationRoundtrip() throws {
        let original = DiffAnnotation(
            path: "kernel-billing/audit/log.go",
            lineStart: 42,
            lineEnd: 47,
            severity: .warning,
            body: "consider buffering writes here"
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DiffAnnotation.self, from: encoded)
        XCTAssertEqual(original, decoded)

        // Confirm wire shape uses snake_case.
        let s = String(data: encoded, encoding: .utf8)!
        XCTAssertTrue(s.contains("\"line_start\":42"))
        XCTAssertTrue(s.contains("\"line_end\":47"))
    }

    func testDisplayTitleUsesProvidedTitle() {
        let a = DiffAnnotation(
            path: "x.go", lineStart: 1, lineEnd: 1,
            severity: .warning, title: "Missing nil check on cache miss",
            body: "long explanation here. With multiple sentences."
        )
        XCTAssertEqual(a.displayTitle, "Missing nil check on cache miss")
    }

    func testDisplayTitleFallsBackToFirstSentence() {
        let a = DiffAnnotation(
            path: "x.go", lineStart: 1, lineEnd: 1,
            severity: .warning,
            body: "Missing nil check. Could panic on cache miss."
        )
        XCTAssertEqual(a.displayTitle, "Missing nil check")
    }

    func testDisplayTitleTruncatesOverLongFallback() {
        let body = String(repeating: "a", count: 200)
        let a = DiffAnnotation(
            path: "x.go", lineStart: 1, lineEnd: 1,
            severity: .warning, body: body
        )
        XCTAssertTrue(a.displayTitle.hasSuffix("…"))
        XCTAssertLessThanOrEqual(a.displayTitle.count, 81)
    }

    func testTitleIsOptionalWhenDecoding() throws {
        // Old reviews cached before titles were added must still decode.
        let json = #"{"path":"x.go","line_start":1,"line_end":1,"severity":"info","body":"a"}"#
        let decoded = try JSONDecoder().decode(DiffAnnotation.self, from: Data(json.utf8))
        XCTAssertNil(decoded.title)
        XCTAssertEqual(decoded.displayTitle, "a")
    }
}
