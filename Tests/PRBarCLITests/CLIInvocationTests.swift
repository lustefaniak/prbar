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
    private func decode(_ text: String) throws -> PRBarConfig {
        try ConfigFile.decode(text).config
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prbar-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testEmptyFileDecodesToShippedDefaults() throws {
        for text in ["", "{}", "version: 1\n"] {
            let cfg = try decode(text)
            XCTAssertEqual(cfg.defaultProvider, .auto)
            XCTAssertEqual(cfg.repositories, RepositoryScope())
            // The gates that post to GitHub stay off unless asked for.
            let resolved = cfg.resolver()("o", "r")
            XCTAssertFalse(resolved.autoApprove.enabled)
            XCTAssertEqual(resolved.shareFindings, .off)
        }
    }

    func testRepositoryListsApply() throws {
        let cfg = try decode("""
        defaults:
          aiReviewEnabled: true
        repositories:
          triage: ["o/*", "!o/r"]
          hide: [o/hidden]
        """)
        XCTAssertFalse(cfg.resolver()("o", "r").aiReviewEnabled, "outside triage")
        XCTAssertTrue(cfg.resolver()("o", "other").aiReviewEnabled)
        XCTAssertTrue(cfg.resolver()("o", "hidden").excluded)
    }

    func testJSONStillLoads() throws {
        let cfg = try decode(#"{"defaultProvider": "codex", "repositories": {"hide": ["o/r"]}}"#)
        XCTAssertEqual(cfg.defaultProvider, .codex)
        XCTAssertTrue(cfg.resolver()("o", "r").excluded)
    }

    func testMissingConfigIsOnlyAnErrorWhenExplicitlyRequested() throws {
        let empty = try tempDir()
        XCTAssertNoThrow(try CLIConfig.load(path: nil, environment: [:], workingDirectory: empty, home: empty))
        XCTAssertThrowsError(try CLIConfig.load(path: "/nonexistent/prbar.yaml", environment: [:]))
        XCTAssertThrowsError(try CLIConfig.load(path: nil, environment: ["PRBAR_CONFIG": "/nonexistent/prbar.yaml"]))
    }

    func testFallsBackToTheAppsUserConfig() throws {
        let home = try tempDir()
        let cwd = try tempDir()
        let user = home.appendingPathComponent(".config/prbar/prbar.yaml")
        try ConfigFile.write("defaultProvider: codex\n", to: user)
        let cfg = try CLIConfig.load(path: nil, environment: [:], workingDirectory: cwd, home: home)
        XCTAssertEqual(cfg.defaultProvider, .codex)

        // A config in the working directory wins over the user one.
        try ConfigFile.write("defaultProvider: claude\n", to: cwd.appendingPathComponent("prbar.yaml"))
        let local = try CLIConfig.load(path: nil, environment: [:], workingDirectory: cwd, home: home)
        XCTAssertEqual(local.defaultProvider, .claude)
    }

    func testUnknownKeysAreReportedNotFatal() throws {
        var warnings: [String] = []
        let dir = try tempDir()
        let url = dir.appendingPathComponent("prbar.yaml")
        try ConfigFile.write("""
        defaultProvidr: codex
        defaults:
          maxCostUsdPerSubreview: 2
          autoApprove:
            enabld: true
        repositories:
          trustRule: [o/r]
        """, to: url)
        let cfg = try CLIConfig.load(path: url.path, environment: [:], warn: { warnings.append($0) })
        XCTAssertEqual(cfg.defaults.maxCostUsdPerSubreview, 2)
        XCTAssertEqual(warnings.count, 3, "\(warnings)")
        XCTAssertTrue(warnings.contains { $0.contains("`defaultProvidr`") })
        XCTAssertTrue(warnings.contains { $0.contains("`defaults.autoApprove.enabld`") })
        XCTAssertTrue(warnings.contains { $0.contains("`repositories.trustRule`") })
    }

    func testMalformedYAMLAndFutureVersionsAreErrors() {
        XCTAssertThrowsError(try decode("defaults: [unclosed"))
        XCTAssertThrowsError(try decode("- a\n- b\n"), "top level must be a mapping")
        XCTAssertThrowsError(try decode("version: 99\n"))
        XCTAssertThrowsError(try decode("repos:\n  - excluded: true\n"), "repos: moved to rules")
    }

    /// The file the app writes must read back to the same value, and must
    /// stay sparse: only what differs from the shipped defaults.
    func testEncodeRoundTripsAndStaysSparse() throws {
        var cfg = PRBarConfig()
        XCTAssertEqual(try ConfigFile.encode(cfg), ConfigFile.header + "version: 1\n")

        cfg.defaultProvider = .codex
        cfg.defaultClaudeModel = ""
        cfg.defaults.maxCostUsdPerSubreview = 7.5
        cfg.defaults.shareFindings = .off
        cfg.defaults.autoDeny.action = .off
        cfg.defaults.excludeTitlePatterns = ["chore: bump *", "!keep: *"]
        cfg.defaults.agentEnvironment = ["CLAUDE_CONFIG_DIR": "~/.claude-work"]
        cfg.defaults.customSystemPrompt = "Line one.\nLine two: with a colon."
        cfg.repositories = RepositoryScope(triage: ["o/*"], trustRules: ["o/r"])

        cfg.defaults.shareMinConfidence = 0.65
        cfg.defaults.autoApprove.minConfidence = 0.9

        let text = try ConfigFile.encode(cfg)
        XCTAssertFalse(text.contains("id:"), "rule ids are UI identity, not file content")
        XCTAssertTrue(text.contains("shareMinConfidence: 0.65"), "plain decimals, not 6.5e-1:\n\(text)")
        XCTAssertTrue(text.contains("minConfidence: 0.9"), text)
        XCTAssertFalse(text.contains("maxAnnotations"), "nested gates stay sparse too")
        XCTAssertFalse(text.contains("reviewTimeoutSeconds"), "unchanged defaults are not written")

        let back = try ConfigFile.decode(text).config
        XCTAssertEqual(back, cfg)
        XCTAssertTrue(try ConfigFile.decode(text).warnings.isEmpty)
    }
}

/// The example config is documentation, and `ReviewDefaults.init(from:)`
/// decodes field by field with `try?` — so a renamed field or a wrong enum
/// value in the example is silently ignored rather than throwing. These
/// assertions are what keeps it honest.
final class ExampleConfigTests: XCTestCase {
    private func loadExample() throws -> ConfigFile.Loaded {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PRBarCLITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        return try ConfigFile.load(url: root.appendingPathComponent("docs/prbar.example.yaml"))
    }

    func testExampleHasNoUnknownKeys() throws {
        XCTAssertEqual(try loadExample().warnings, [])
    }

    func testExampleAppLevelValuesDecode() throws {
        let cfg = try loadExample().config
        XCTAssertEqual(cfg.defaultProvider, .claude)
        XCTAssertEqual(cfg.defaultClaudeModel, "sonnet")
        XCTAssertEqual(cfg.defaultClaudeEffort, "")

        let base = cfg.resolver()("acme", "repo")
        XCTAssertEqual(base.toolMode, .sandboxed)
        XCTAssertEqual(base.splitMode, .perSubfolder)
        XCTAssertEqual(base.maxParallelSubreviews, 2)
        XCTAssertEqual(base.maxCostUsdPerSubreview, 3.0)
        XCTAssertEqual(base.shareFindings, .warningsAndBlockers)
        XCTAssertEqual(base.shareMaxComments, 20)
        XCTAssertEqual(base.excludeTitlePatterns, ["chore: bump *", "Release *"])
        XCTAssertFalse(base.autoApprove.enabled)
        XCTAssertEqual(base.autoDeny.action, .off)
        XCTAssertFalse(base.resolveThreads.enabled)

        XCTAssertEqual(cfg.agents.read, .allow)
        XCTAssertEqual(cfg.agents.review, .allow)
        XCTAssertEqual(cfg.agents.post, .off)
        XCTAssertEqual(cfg.agents.merge, .off)
    }

    func testExampleConfigureRulesAndRepositoryLists() throws {
        var cfg = try loadExample().config
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        cfg.compiledRules = try RuleDirectory.load(root.appendingPathComponent("docs/rules.example"))

        let monorepo = cfg.resolver()("acme", "monorepo")
        XCTAssertEqual(monorepo.providerOverride, .codex)
        XCTAssertEqual(monorepo.shareFindings, .allFindings, "the rule wins over defaults")
        XCTAssertEqual(monorepo.collapseAboveSubreviewCount, 8)
        XCTAssertEqual(monorepo.rootPatterns, ["kernel-*", "lib/*", "dev-tools"])
        XCTAssertEqual(monorepo.maxParallelSubreviews, 2, "unset fields come from defaults")
        XCTAssertTrue(monorepo.trustRepoRules)

        let mine = cfg.resolver()("me", "tool")
        XCTAssertEqual(mine.splitMode, .single)
        XCTAssertTrue(mine.autoApprove.enabled)
        XCTAssertEqual(mine.autoApprove.maxAdditions, 100)

        XCTAssertTrue(cfg.resolver()("acme", "infra-tools").excluded, "glob should match")
        XCTAssertFalse(cfg.resolver()("acme", "tools").excluded)
        XCTAssertFalse(cfg.resolver()("stranger", "repo").aiReviewEnabled, "outside triage")
    }
}
