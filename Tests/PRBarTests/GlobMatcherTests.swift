import XCTest
@testable import PRBar

final class GlobMatcherTests: XCTestCase {
    func testStarMatchesSingleSegment() {
        XCTAssertTrue(GlobMatcher.match("kernel-*", "kernel-billing"))
        XCTAssertTrue(GlobMatcher.match("kernel-*", "kernel-auth"))
        XCTAssertFalse(GlobMatcher.match("kernel-*", "kernel-billing/foo.go"))
        XCTAssertFalse(GlobMatcher.match("kernel-*", "lib/kernel-billing"))
    }

    func testDoubleStarMatchesAcrossSlashes() {
        XCTAssertTrue(GlobMatcher.match("kernel-*/**", "kernel-billing/audit/log.go"))
        XCTAssertTrue(GlobMatcher.match("**", "any/path/here.go"))
    }

    func testQuestionMark() {
        XCTAssertTrue(GlobMatcher.match("v?", "v1"))
        XCTAssertFalse(GlobMatcher.match("v?", "v10"))
        XCTAssertFalse(GlobMatcher.match("v?", "v/1"))
    }

    func testLiteralWins() {
        XCTAssertTrue(GlobMatcher.match("dev-infra", "dev-infra"))
        XCTAssertFalse(GlobMatcher.match("dev-infra", "dev-infrastructure"))
    }

    func testSpecificityOrdering() {
        // Literal beats wildcard
        XCTAssertGreaterThan(
            GlobMatcher.specificity("kernel-billing"),
            GlobMatcher.specificity("kernel-*")
        )
        // Two-segment literal beats single literal
        XCTAssertGreaterThan(
            GlobMatcher.specificity("lib/auth"),
            GlobMatcher.specificity("lib/*")
        )
    }

    func testAnyMatchWithNegation() {
        let patterns = ["getsynq/*", "!getsynq/cloud"]
        XCTAssertTrue(GlobMatcher.anyMatch(patterns, "getsynq/recon"))
        XCTAssertFalse(GlobMatcher.anyMatch(patterns, "getsynq/cloud"))
        XCTAssertFalse(GlobMatcher.anyMatch(patterns, "other/repo"))
    }

    func testRegexMetacharsAreEscaped() {
        // Pattern containing dots should match literal dots only.
        XCTAssertTrue(GlobMatcher.match("foo.bar", "foo.bar"))
        XCTAssertFalse(GlobMatcher.match("foo.bar", "fooXbar"))
    }
}
