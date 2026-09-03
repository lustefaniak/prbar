import XCTest
@testable import PRBar

final class ProviderRelevanceTests: XCTestCase {
    func testSuppressionOffWarnsAboutEveryProvider() {
        let relevant = ProviderRelevance.relevantProviders(
            suppressionEnabled: false,
            defaultProviderRaw: ProviderID.claude.rawValue,
            repoOverrides: []
        )
        XCTAssertEqual(relevant, Set(ProviderID.allCases))
    }

    func testSuppressionOffIgnoresRepoOverrides() {
        // The off-path is an early return that must discard all config,
        // not coincidentally widen to it. The override must COINCIDE with
        // the default (both .claude) so the post-guard set would be the
        // strict subset {.claude}: dropping the guard fails this test,
        // whereas a non-overlapping override would union back to allCases
        // and hide the regression.
        let relevant = ProviderRelevance.relevantProviders(
            suppressionEnabled: false,
            defaultProviderRaw: ProviderID.claude.rawValue,
            repoOverrides: [.claude]
        )
        XCTAssertEqual(relevant, Set(ProviderID.allCases))
    }

    func testConcreteDefaultDropsTheOtherProvider() {
        let claudeOnly = ProviderRelevance.relevantProviders(
            suppressionEnabled: true,
            defaultProviderRaw: ProviderID.claude.rawValue,
            repoOverrides: []
        )
        XCTAssertEqual(claudeOnly, [.claude])

        let codexOnly = ProviderRelevance.relevantProviders(
            suppressionEnabled: true,
            defaultProviderRaw: ProviderID.codex.rawValue,
            repoOverrides: []
        )
        XCTAssertEqual(codexOnly, [.codex])
    }

    func testAutoKeepsBothProviders() {
        let relevant = ProviderRelevance.relevantProviders(
            suppressionEnabled: true,
            defaultProviderRaw: ProviderID.autoSentinel,
            repoOverrides: []
        )
        XCTAssertEqual(relevant, Set(ProviderID.allCases))
    }

    func testRepoOverrideReintroducesAProvider() {
        let relevant = ProviderRelevance.relevantProviders(
            suppressionEnabled: true,
            defaultProviderRaw: ProviderID.claude.rawValue,
            repoOverrides: [.codex]
        )
        XCTAssertEqual(relevant, [.claude, .codex])
    }

    func testRepoOverrideMatchingDefaultDoesNotWiden() {
        // With only two providers, {.claude, .codex} coincides with
        // allCases, so testRepoOverrideReintroducesAProvider alone can't
        // distinguish the union path from a wrong fall-back-to-everything.
        // An override that names the same provider as the default must
        // stay at exactly that one provider, never widen to both.
        let relevant = ProviderRelevance.relevantProviders(
            suppressionEnabled: true,
            defaultProviderRaw: ProviderID.codex.rawValue,
            repoOverrides: [.codex]
        )
        XCTAssertEqual(relevant, [.codex])
    }

    func testUnrecognisedDefaultFallsBackToWarningAboutEverything() {
        let relevant = ProviderRelevance.relevantProviders(
            suppressionEnabled: true,
            defaultProviderRaw: "not-a-real-provider",
            repoOverrides: []
        )
        XCTAssertEqual(relevant, Set(ProviderID.allCases))
    }

    // MARK: - isSuppressed (probe-result → warning bridge)

    func testMissingNonProviderToolIsNeverSuppressed() {
        // gh / git aren't AI providers; a missing one is always a real
        // warning, never silenced as "not used".
        XCTAssertFalse(ProviderRelevance.isSuppressed(
            toolName: "gh", available: false, relevantProviders: [.claude]))
        XCTAssertFalse(ProviderRelevance.isSuppressed(
            toolName: "git", available: false, relevantProviders: []))
    }

    func testInstalledProviderIsNeverSuppressed() {
        XCTAssertFalse(ProviderRelevance.isSuppressed(
            toolName: ProviderID.codex.rawValue,
            available: true,
            relevantProviders: [.claude]))
    }

    func testMissingIrrelevantProviderIsSuppressed() {
        XCTAssertTrue(ProviderRelevance.isSuppressed(
            toolName: ProviderID.codex.rawValue,
            available: false,
            relevantProviders: [.claude]))
    }

    func testMissingRelevantProviderIsNotSuppressed() {
        XCTAssertFalse(ProviderRelevance.isSuppressed(
            toolName: ProviderID.claude.rawValue,
            available: false,
            relevantProviders: [.claude]))
    }
}
