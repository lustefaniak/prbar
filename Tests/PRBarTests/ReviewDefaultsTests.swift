import XCTest
@testable import PRBar

final class ReviewDefaultsTests: XCTestCase {
    // MARK: - precedence

    func testUnsetFieldsInheritFromDefaults() {
        var defaults = ReviewDefaults()
        defaults.maxCostUsdPerSubreview = 7.5
        defaults.reviewTimeoutSeconds = 900
        defaults.aiReviewEnabled = false

        let cfg = RepoConfig(repoGlobs: ["acme/x"]).resolved(with: defaults)

        XCTAssertEqual(cfg.maxCostUsdPerSubreview, 7.5)
        XCTAssertEqual(cfg.reviewTimeoutSeconds, 900)
        XCTAssertFalse(cfg.aiReviewEnabled)
    }

    func testRuleOverrideWinsOverDefaults() {
        var defaults = ReviewDefaults()
        defaults.maxCostUsdPerSubreview = 7.5
        defaults.notifyPolicy = .batchSettled

        var rule = RepoConfig(repoGlobs: ["acme/x"])
        rule.maxCostUsdPerSubreview = 0.25
        rule.notifyPolicy = .eachReady

        let cfg = rule.resolved(with: defaults)
        XCTAssertEqual(cfg.maxCostUsdPerSubreview, 0.25)
        XCTAssertEqual(cfg.notifyPolicy, .eachReady)
    }

    /// An override that happens to equal the default is still an override —
    /// changing the default later must not move it.
    func testOverrideEqualToDefaultDoesNotTrackTheDefault() {
        var rule = RepoConfig(repoGlobs: ["acme/x"])
        rule.maxParallelSubreviews = ReviewDefaults().maxParallelSubreviews

        var defaults = ReviewDefaults()
        defaults.maxParallelSubreviews = 6

        XCTAssertEqual(rule.resolved(with: defaults).maxParallelSubreviews,
                       ReviewDefaults().maxParallelSubreviews)
    }

    func testPerRepoOnlyFieldsPassThrough() {
        var rule = RepoConfig(repoGlobs: ["acme/*", "!acme/secret"])
        rule.rootPatterns = ["kernel-*"]
        rule.excluded = true

        let cfg = rule.resolved()
        XCTAssertEqual(cfg.repoGlobs, ["acme/*", "!acme/secret"])
        XCTAssertEqual(cfg.rootPatterns, ["kernel-*"])
        XCTAssertTrue(cfg.excluded)
        XCTAssertTrue(cfg.matches(nameWithOwner: "acme/tools"))
        XCTAssertFalse(cfg.matches(nameWithOwner: "acme/secret"))
    }

    // MARK: - sentinels

    /// `nil` means inherit, so "off" needed a different marker.
    func testCollapseAboveSubreviewCountUsesZeroForOff() {
        var defaults = ReviewDefaults()
        defaults.collapseAboveSubreviewCount = 5

        var rule = RepoConfig(repoGlobs: ["acme/x"])
        XCTAssertEqual(rule.resolved(with: defaults).collapseAboveSubreviewCount, 5,
                       "nil on the rule inherits")

        rule.collapseAboveSubreviewCount = 0
        XCTAssertNil(rule.resolved(with: defaults).collapseAboveSubreviewCount,
                     "0 disables collapsing rather than inheriting")

        rule.collapseAboveSubreviewCount = 3
        XCTAssertEqual(rule.resolved(with: defaults).collapseAboveSubreviewCount, 3)
    }

    func testCustomSystemPromptUsesEmptyStringForNone() {
        var defaults = ReviewDefaults()
        defaults.customSystemPrompt = "house style rules"

        var rule = RepoConfig(repoGlobs: ["acme/x"])
        XCTAssertEqual(rule.resolved(with: defaults).customSystemPrompt, "house style rules")

        rule.customSystemPrompt = ""
        XCTAssertNil(rule.resolved(with: defaults).customSystemPrompt,
                     "empty opts this repo out of the global prompt")

        rule.customSystemPrompt = "repo specific"
        XCTAssertEqual(rule.resolved(with: defaults).customSystemPrompt, "repo specific")
    }

    func testZeroCostCapMeansUncapped() {
        var defaults = ReviewDefaults()
        defaults.maxCostUsdPerSubreview = 0
        XCTAssertEqual(RepoConfig(repoGlobs: ["a/b"]).resolved(with: defaults).maxCostUsdPerSubreview, 0)
    }

    // MARK: - title patterns

    func testExcludeTitlePatternsUnionRatherThanReplace() {
        var defaults = ReviewDefaults()
        defaults.excludeTitlePatterns = ["chore: bump *"]

        var rule = RepoConfig(repoGlobs: ["acme/x"])
        XCTAssertEqual(rule.resolved(with: defaults).excludeTitlePatterns, ["chore: bump *"])

        rule.excludeTitlePatterns = ["[Prod deploy]*"]
        XCTAssertEqual(rule.resolved(with: defaults).excludeTitlePatterns,
                       ["chore: bump *", "[Prod deploy]*"])
    }

    /// The union has no "clear the global list" switch by design — a repo
    /// opts out of one global pattern by negating it, which is what
    /// `GlobMatcher` already supports.
    func testRepoCanNegateAGlobalTitlePattern() {
        var defaults = ReviewDefaults()
        defaults.excludeTitlePatterns = ["chore: bump *"]

        var rule = RepoConfig(repoGlobs: ["acme/x"])
        rule.excludeTitlePatterns = ["!chore: bump *"]

        let patterns = rule.resolved(with: defaults).excludeTitlePatterns
        XCTAssertFalse(GlobMatcher.anyMatch(patterns, "chore: bump golangci-lint"))
    }

    // MARK: - auto-review inheritance

    func testAutoReviewInheritsAsAWholeStruct() {
        var defaults = ReviewDefaults()
        defaults.autoApprove = AutoApproveConfig(enabled: true, minConfidence: 0.95, maxAdditions: 50)

        let inheriting = RepoConfig(repoGlobs: ["acme/x"]).resolved(with: defaults)
        XCTAssertTrue(inheriting.autoApprove.enabled)
        XCTAssertEqual(inheriting.autoApprove.minConfidence, 0.95)

        var opted = RepoConfig(repoGlobs: ["acme/y"])
        opted.autoApprove = .off
        XCTAssertFalse(opted.resolved(with: defaults).autoApprove.enabled,
                       "an explicit .off must not fall back to an armed global policy")
    }

    /// Shipping an armed auto-review default would let PRBar post on repos
    /// the user never configured — the whole reason these are opt-in.
    func testShippedDefaultsLeaveAutoReviewOff() {
        let defaults = ReviewDefaults()
        XCTAssertFalse(defaults.autoApprove.enabled)
        XCTAssertEqual(defaults.autoDeny.action, .off)
    }

    // MARK: - Codable

    func testDecodesForwardCompatiblyFromAPartialPayload() throws {
        let json = #"{"maxCostUsdPerSubreview": 12.5}"#
        let decoded = try JSONDecoder().decode(ReviewDefaults.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.maxCostUsdPerSubreview, 12.5)
        // Everything absent falls back to the shipped value rather than
        // zeroing out.
        XCTAssertEqual(decoded.reviewTimeoutSeconds, ReviewDefaults().reviewTimeoutSeconds)
        XCTAssertEqual(decoded.churnHistoryDepth, ReviewDefaults().churnHistoryDepth)
        XCTAssertTrue(decoded.aiReviewEnabled)
    }

    func testRoundTrips() throws {
        var defaults = ReviewDefaults()
        defaults.maxCostUsdPerSubreview = 4.25
        defaults.toolMode = .minimal
        defaults.excludeTitlePatterns = ["release/*"]
        defaults.autoDeny = AutoDenyConfig(action: .flagOnly, minConfidence: 0.7)

        let data = try JSONEncoder().encode(defaults)
        XCTAssertEqual(try JSONDecoder().decode(ReviewDefaults.self, from: data), defaults)
    }

    /// `RepoConfig.default` is what an unmatched repo and a freshly-added
    /// rule both start from: it must override nothing.
    func testRepoConfigDefaultOverridesNothing() {
        let rule = RepoConfig.default
        XCTAssertNil(rule.maxCostUsdPerSubreview)
        XCTAssertNil(rule.splitMode)
        XCTAssertNil(rule.autoApprove)
        XCTAssertNil(rule.aiReviewEnabled)

        var defaults = ReviewDefaults()
        defaults.maxCostUsdPerSubreview = 9
        XCTAssertEqual(rule.resolved(with: defaults).maxCostUsdPerSubreview, 9)
    }
}
