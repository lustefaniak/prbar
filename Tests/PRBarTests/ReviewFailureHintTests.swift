import XCTest
@testable import PRBar

final class ReviewFailureHintTests: XCTestCase {
    /// The message a user actually reported not being able to act on.
    func testPerSubreviewCostCapPointsAtReviewDefaults() {
        let message = "claude review stopped by the per-subreview cost cap — $1.0031 spent (cap $1.00). "
            + "Raise \"Max cost / subreview\" in Settings → Review defaults."
        XCTAssertEqual(ReviewFailureHint.hint(for: message)?.destination, .reviewDefaults)
    }

    /// Reviews recovered from the store still carry the pre-rewording
    /// text, so the older phrasing has to keep resolving.
    func testLegacyBudgetWordingStillResolves() {
        XCTAssertEqual(
            ReviewFailureHint.hint(for: "claude review exceeded budget: $1.0031 spent (cap $1.00)")?.destination,
            .reviewDefaults
        )
    }

    /// Both mention cost and they live in different tabs, so the daily cap
    /// must not be swallowed by the per-subreview branch.
    func testDailyCapPointsAtGeneral() {
        XCTAssertEqual(
            ReviewFailureHint.hint(for: "Daily $5.00 cap reached. Raise it in Settings → General.")?.destination,
            .general
        )
    }

    func testTimeoutPointsAtReviewDefaults() {
        XCTAssertEqual(ReviewFailureHint.hint(for: "claude exited 143: ")?.destination, .reviewDefaults)
        XCTAssertEqual(ReviewFailureHint.hint(for: "review timed out after 600s")?.destination, .reviewDefaults)
    }

    func testMissingCLIPointsAtDiagnostics() {
        XCTAssertEqual(
            ReviewFailureHint.hint(for: "codex CLI not found. Install codex, then `codex login`.")?.destination,
            .diagnostics
        )
    }

    /// A failure with no setting behind it must not offer a misleading
    /// "go change this" button.
    func testUnrelatedFailureHasNoHint() {
        XCTAssertNil(ReviewFailureHint.hint(for: "Could not decode claude's structured_output: unexpected token"))
        XCTAssertNil(ReviewFailureHint.hint(for: "claude returned no structured_output"))
    }

    /// Every tab a hint can point at must be reachable, and the indices
    /// have to match SettingsRoot's TabView order.
    func testDestinationIndicesAreUniqueAndOrdered() {
        let indices = SettingsDestination.allCases.map(\.tabIndex)
        XCTAssertEqual(indices, Array(0..<SettingsDestination.allCases.count))
        XCTAssertEqual(SettingsDestination.reviewDefaults.settingsPath, "Settings → Review defaults")
    }
}
