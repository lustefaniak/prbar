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
}
