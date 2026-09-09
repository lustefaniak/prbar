import XCTest
@testable import PRBar

/// Environment variables handed to `claude` / `codex`, and the two ways
/// this can go wrong quietly: a repo silently losing the global set, and a
/// child process losing HOME/PATH because the override replaced rather
/// than layered.
final class AgentEnvironmentTests: XCTestCase {

    // MARK: - resolution

    func testRepoVariablesLayerOnTopOfGlobalOnes() {
        var defaults = ReviewDefaults()
        defaults.agentEnvironment = ["CLAUDE_CONFIG_DIR": "/global", "SHARED": "keep"]
        var rule = RepoConfig.default
        rule.agentEnvironment = ["CLAUDE_CONFIG_DIR": "/repo", "EXTRA": "1"]

        let resolved = rule.resolved(with: defaults).agentEnvironment

        XCTAssertEqual(resolved["CLAUDE_CONFIG_DIR"], "/repo", "the repo wins on a shared key")
        XCTAssertEqual(resolved["SHARED"], "keep", "a global the repo didn't mention survives")
        XCTAssertEqual(resolved["EXTRA"], "1")
    }

    func testNilRuleInheritsTheGlobalSetUntouched() {
        var defaults = ReviewDefaults()
        defaults.agentEnvironment = ["CLAUDE_CONFIG_DIR": "/global"]
        let rule = RepoConfig.default   // agentEnvironment stays nil

        XCTAssertEqual(rule.resolved(with: defaults).agentEnvironment,
                       ["CLAUDE_CONFIG_DIR": "/global"])
    }

    /// An empty string is a legitimate environment value, so it cannot
    /// double as "unset" — hence the `!NAME` escape hatch.
    func testBangKeyDropsAnInheritedVariable() {
        var defaults = ReviewDefaults()
        defaults.agentEnvironment = ["CLAUDE_CONFIG_DIR": "/global", "KEEP": "yes"]
        var rule = RepoConfig.default
        rule.agentEnvironment = ["!CLAUDE_CONFIG_DIR": ""]

        let resolved = rule.resolved(with: defaults).agentEnvironment

        XCTAssertNil(resolved["CLAUDE_CONFIG_DIR"], "the negated key is gone")
        XCTAssertNil(resolved["!CLAUDE_CONFIG_DIR"], "and the marker itself never reaches the child")
        XCTAssertEqual(resolved["KEEP"], "yes")
    }

    func testEmptyValueIsPreservedRatherThanTreatedAsUnset() {
        var defaults = ReviewDefaults()
        defaults.agentEnvironment = ["FLAG": "1"]
        var rule = RepoConfig.default
        rule.agentEnvironment = ["FLAG": ""]

        XCTAssertEqual(rule.resolved(with: defaults).agentEnvironment["FLAG"], "",
                       "setting a variable to empty is not the same as removing it")
    }

    // MARK: - process environment

    /// The documented footgun: `ProcessRunner.childEnvironment` *replaces*
    /// the environment when handed one, so a bare override dictionary
    /// strips HOME/USER/PATH from the child.
    func testOverridesAreLayeredOntoTheInheritedEnvironment() throws {
        let env = try XCTUnwrap(
            ProcessRunner.inheritedEnvironment(overrides: ["CLAUDE_CONFIG_DIR": "/tmp/x"])
        )
        XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], "/tmp/x")
        XCTAssertNotNil(env["HOME"], "the inherited environment must survive")
        XCTAssertNotNil(env["PATH"])
    }

    /// Nil keeps the untouched path byte-identical to before rather than
    /// round-tripping the whole environment for no reason.
    func testNoOverridesMeansNoEnvironmentArgument() {
        XCTAssertNil(ProcessRunner.inheritedEnvironment(overrides: [:]))
    }

    /// A user-set PATH must not cost us the Homebrew dirs — a GUI-launched
    /// app inherits a LaunchServices PATH that has none of them.
    func testSearchPathsStillPrependedWhenTheUserOverridesPath() {
        let merged = ProcessRunner.inheritedEnvironment(overrides: ["PATH": "/only/this"])
        let env = ProcessRunner.childEnvironment(merged, prepending: ["/opt/homebrew/bin"])
        let path = env["PATH"] ?? ""
        XCTAssertTrue(path.hasPrefix("/opt/homebrew/bin"), "got: \(path)")
        XCTAssertTrue(path.contains("/only/this"))
    }

    /// End-to-end: the whole chain is only worth anything if the variable
    /// actually lands in the child. Runs a real subprocess.
    func testVariableReachesARealChildProcess() async throws {
        let result = try await ProcessRunner.run(
            executable: "/bin/sh",
            args: ["-c", "printf '%s|%s' \"$PRBAR_TEST_VAR\" \"${HOME:+home-present}\""],
            environment: ProcessRunner.inheritedEnvironment(overrides: ["PRBAR_TEST_VAR": "hello"])
        )
        XCTAssertEqual(result.stdoutString, "hello|home-present",
                       "the override must arrive and the inherited environment must survive")
    }

    // MARK: - editor parsing

    func testParsesKeyValueLines() {
        let parsed = ReviewSettingControls.EnvironmentEditor.parse("""
        CLAUDE_CONFIG_DIR=/Users/me/.claude-review
        EMPTY=
        # a comment
        !DROPPED

        SPACED = /with/spaces
        """)
        XCTAssertEqual(parsed["CLAUDE_CONFIG_DIR"], "/Users/me/.claude-review")
        XCTAssertEqual(parsed["EMPTY"], "")
        XCTAssertEqual(parsed["SPACED"], " /with/spaces", "only the key is trimmed")
        XCTAssertEqual(parsed["!DROPPED"], "")
        XCTAssertNil(parsed["# a comment"])
        XCTAssertEqual(parsed.count, 4)
    }

    /// Values legitimately contain `=` — a URL with a query, a path list.
    func testSplitsOnTheFirstEqualsOnly() {
        let parsed = ReviewSettingControls.EnvironmentEditor.parse("URL=https://x/y?a=1&b=2")
        XCTAssertEqual(parsed["URL"], "https://x/y?a=1&b=2")
    }

    /// A half-typed line must not land as an empty-valued variable, which
    /// would silently set it in the child.
    func testBareWordIsIgnoredWhileTyping() {
        XCTAssertTrue(ReviewSettingControls.EnvironmentEditor.parse("CLAUDE_CONF").isEmpty)
    }

    func testFormatRoundTripsAndIsStablyOrdered() {
        let vars = ["B": "2", "A": "1", "!C": ""]
        let text = ReviewSettingControls.EnvironmentEditor.format(vars)
        XCTAssertEqual(text, "!C\nA=1\nB=2")
        XCTAssertEqual(ReviewSettingControls.EnvironmentEditor.parse(text), vars)
    }

    // MARK: - persistence

    /// Old payloads predate the field; new ones must survive a round trip.
    func testCodableRoundTripAndForwardCompatibility() throws {
        var cfg = RepoConfig.default
        cfg.agentEnvironment = ["CLAUDE_CONFIG_DIR": "/x"]
        let back = try JSONDecoder().decode(RepoConfig.self, from: JSONEncoder().encode(cfg))
        XCTAssertEqual(back.agentEnvironment, ["CLAUDE_CONFIG_DIR": "/x"])

        let legacy = Data(#"{"id":"\#(UUID().uuidString)","repoGlobs":["o/r"]}"#.utf8)
        let decoded = try JSONDecoder().decode(RepoConfig.self, from: legacy)
        XCTAssertNil(decoded.agentEnvironment, "a payload without the key inherits")
    }

    func testDefaultsCodableRoundTrip() throws {
        var d = ReviewDefaults()
        d.agentEnvironment = ["A": "1"]
        let back = try JSONDecoder().decode(ReviewDefaults.self, from: JSONEncoder().encode(d))
        XCTAssertEqual(back.agentEnvironment, ["A": "1"])

        let legacy = try JSONDecoder().decode(ReviewDefaults.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.agentEnvironment, [:])
    }
}
