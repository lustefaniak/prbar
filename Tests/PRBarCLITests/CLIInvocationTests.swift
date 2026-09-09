import XCTest
@testable import PRBarCore

/// Covers the CLI's own logic — argument grammar, PR-address parsing, and
/// the config chain. The review pipeline itself is covered by the app's
/// test suite; these are the parts that only exist for the headless path.
final class CLIInvocationTests: XCTestCase {
    func testParsesPullRequestURL() {
        let t = Invocation.parseTarget("https://github.com/getsynq/cloud/pull/19892")
        XCTAssertEqual(t?.owner, "getsynq")
        XCTAssertEqual(t?.repo, "cloud")
        XCTAssertEqual(t?.number, 19892)
    }

    func testParsesURLWithTrailingPathAndQuery() {
        // The forms that actually get pasted: a deep link to a file in the
        // diff, and a URL carrying tracking params.
        XCTAssertEqual(
            Invocation.parseTarget("https://github.com/o/r/pull/7/files")?.number, 7)
        XCTAssertEqual(
            Invocation.parseTarget("https://github.com/o/r/pull/7?diff=split")?.number, 7)
    }

    func testParsesShorthand() {
        let t = Invocation.parseTarget("lustefaniak/prbar#40")
        XCTAssertEqual(t?.owner, "lustefaniak")
        XCTAssertEqual(t?.repo, "prbar")
        XCTAssertEqual(t?.number, 40)
    }

    func testRejectsAddressesWithoutAPRNumber() {
        for bad in ["https://github.com/o/r", "https://github.com/o/r/pull/abc",
                    "o/r", "o/r#", "pull/12", ""] {
            XCTAssertNil(Invocation.parseTarget(bad), "should not parse: \(bad)")
        }
    }

    func testParsesFlags() {
        let inv = Invocation(args: ["--force", "--provider", "codex",
                                    "--config", "/tmp/c.json", "o/r#3"])
        XCTAssertEqual(inv?.force, true)
        XCTAssertEqual(inv?.providerOverride, .codex)
        XCTAssertEqual(inv?.configPath, "/tmp/c.json")
        XCTAssertEqual(inv?.target.number, 3)
    }

    func testRejectsBadInvocations() {
        // An unknown flag, a flag missing its value, a bad provider, two
        // positionals, and no positional at all: all usage errors rather
        // than something silently reviewed.
        XCTAssertNil(Invocation(args: []))
        XCTAssertNil(Invocation(args: ["--nope", "o/r#1"]))
        XCTAssertNil(Invocation(args: ["--provider"]))
        XCTAssertNil(Invocation(args: ["--provider", "gemini", "o/r#1"]))
        XCTAssertNil(Invocation(args: ["o/r#1", "o/r#2"]))
    }

    func testDefaultsAreUsableWithNoFlags() {
        let inv = Invocation(args: ["o/r#1"])
        XCTAssertEqual(inv?.force, false)
        XCTAssertNil(inv?.providerOverride)
        XCTAssertNil(inv?.configPath)
    }
}

final class CLIConfigTests: XCTestCase {
    func testEmptyObjectDecodesToShippedDefaults() throws {
        let cfg = try JSONDecoder().decode(CLIConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(cfg.defaultProvider, .claude)
        XCTAssertTrue(cfg.repos.isEmpty)
        // The gates that post to GitHub stay off unless asked for.
        let resolved = cfg.resolver()("o", "r")
        XCTAssertFalse(resolved.autoApprove.enabled)
        XCTAssertEqual(resolved.shareFindings, .off)
    }

    func testRepoRuleOverridesDefaults() throws {
        let json = """
        {
          "defaults": {"aiReviewEnabled": true},
          "repos": [{"repoGlobs": ["o/r"], "aiReviewEnabled": false}]
        }
        """
        let cfg = try JSONDecoder().decode(CLIConfig.self, from: Data(json.utf8))
        XCTAssertFalse(cfg.resolver()("o", "r").aiReviewEnabled, "repo rule should win")
        XCTAssertTrue(cfg.resolver()("o", "other").aiReviewEnabled, "non-matching repo inherits")
    }

    func testMissingConfigIsOnlyAnErrorWhenExplicitlyRequested() throws {
        XCTAssertNoThrow(try CLIConfig.load(path: nil))
        XCTAssertThrowsError(try CLIConfig.load(path: "/nonexistent/prbar.json"))
    }
}

/// The example config is documentation, and `ReviewDefaults.init(from:)`
/// decodes field by field with `try?` — so a renamed field or a typo in
/// the example is silently ignored rather than throwing. These assertions
/// are what keeps it honest.
final class ExampleConfigTests: XCTestCase {
    private func loadExample() throws -> CLIConfig {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PRBarCLITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let url = root.appendingPathComponent("docs/prbar.example.json")
        return try JSONDecoder().decode(CLIConfig.self, from: try Data(contentsOf: url))
    }

    func testExampleAppLevelValuesDecode() throws {
        let cfg = try loadExample()
        XCTAssertEqual(cfg.defaultProvider, .claude)
        XCTAssertEqual(cfg.defaultClaudeModel, "sonnet")

        let base = cfg.resolver()("some", "repo")
        XCTAssertEqual(base.toolMode, .sandboxed)
        XCTAssertEqual(base.maxParallelSubreviews, 2)
        XCTAssertEqual(base.shareFindings, .warningsAndBlockers)
        XCTAssertEqual(base.excludeTitlePatterns, ["chore: bump *", "Release *"])
        XCTAssertFalse(base.autoApprove.enabled)
        XCTAssertEqual(base.autoDeny.action, .off)
    }

    func testExampleRepoRulesOverrideAndExclude() throws {
        let cfg = try loadExample()

        let cloud = cfg.resolver()("getsynq", "cloud")
        XCTAssertEqual(cloud.providerOverride, .codex)
        XCTAssertEqual(cloud.shareFindings, .allFindings, "repo rule should win over defaults")
        XCTAssertEqual(cloud.collapseAboveSubreviewCount, 8)
        XCTAssertEqual(cloud.rootPatterns, ["kernel-*", "lib/*", "dev-tools"])
        XCTAssertEqual(cloud.maxParallelSubreviews, 2, "unset fields still inherit")

        XCTAssertTrue(cfg.resolver()("anyone", "infra-tools").excluded, "glob should match")
        XCTAssertFalse(cfg.resolver()("anyone", "tools").excluded)
    }
}
