import XCTest
@testable import PRBarCore

/// Per-repository settings as `configure` rules, the `repositories:`
/// lists, and converting the old `repos:` entries into them.
final class ConfigureRulesTests: XCTestCase {
    nonisolated static let oldConfig = """
        version: 1
        defaultClaudeModel: sonnet
        defaults:
          splitMode: single
          autoApprove:
            enabled: true
          shareFindings: warnings_and_blockers
          resolveThreads:
            enabled: true
            minConfidence: 0.85
        repos:
        - repoGlobs:
          - acme/monorepo
          rootPatterns:
          - kernel-*/
          - fe-app/
          splitMode: perSubfolder
          unmatchedStrategy: reviewAtRoot
          minFilesPerSubreview: 10
          collapseAboveSubreviewCount: 2
          maxCostUsdPerSubreview: 3.0
          reviewDrafts: false
          excludeTitlePatterns:
          - '[Prod deploy]*'
          skipAIIfReviewedByOthers: true
          customSystemPrompt: |
            Watch the "billing" module.
            It's old.
          agentEnvironment:
            GOFLAGS: -mod=mod
          forceFullReview: false
        - repoGlobs:
          - me/tool
          autoApprove:
            enabled: false
          autoDeny:
            action: 'off'
          forceFullReview: true
        - repoGlobs:
          - acme/secret-*
          excluded: true
        - repoGlobs:
          - acme/docs
          autoApprove:
            enabled: true
            maxAnnotationSeverity: info
            maxAdditions: 50
        """

    func testTheOldReposKeyIsRefusedWithThePathToConvert() {
        XCTAssertThrowsError(try ConfigFile.decode(Self.oldConfig, path: "/p/prbar.yaml")) { error in
            XCTAssertEqual(error as? ConfigFile.Error, .reposMoved(path: "/p/prbar.yaml"))
            XCTAssertTrue(error.localizedDescription.contains("prbar-review rules convert"))
        }
        XCTAssertNoThrow(try ConfigFile.decode("repos: []\n"), "an empty list has nothing to lose")
    }

    func testConversionKeepsEverySetting() throws {
        let result = try RulesConvert.convert(
            configText: Self.oldConfig, path: "prbar.yaml", rules: [:], rulesRoot: "/r",
            repositories: ["acme/other", "acme/monorepo", "me/tool", "acme/secret-x", "acme/docs"])
        XCTAssertEqual(result.entries, 4)
        XCTAssertTrue(result.checked.contains("acme/secret-x"))

        // What gets written loads on its own, without `repos:`.
        var loaded = try ConfigFile.decode(result.configText).config
        XCTAssertEqual(loaded.repositories.hide, ["acme/secret-*"])
        XCTAssertEqual(loaded.defaultClaudeModel, "sonnet")
        XCTAssertFalse(result.configText.contains("repos:"))
        loaded.compiledRules = try RuleDirectory.compile([result.rulePath: result.ruleText], root: "/r")

        let monorepo = loaded.resolve(owner: "acme", repo: "monorepo")
        XCTAssertEqual(monorepo.splitMode, .perSubfolder)
        XCTAssertEqual(monorepo.rootPatterns, ["kernel-*/", "fe-app/"])
        XCTAssertEqual(monorepo.maxCostUsdPerSubreview, 3.0)
        XCTAssertEqual(monorepo.customSystemPrompt, "Watch the \"billing\" module.\nIt's old.\n")
        XCTAssertEqual(monorepo.agentEnvironment["GOFLAGS"], "-mod=mod")
        XCTAssertTrue(monorepo.autoApprove.enabled, "not set by the entry: the defaults'")

        XCTAssertFalse(loaded.resolve(owner: "me", repo: "tool").autoApprove.enabled)
        XCTAssertTrue(loaded.resolve(owner: "acme", repo: "secret-x").excluded)
        XCTAssertEqual(loaded.resolve(owner: "acme", repo: "docs").autoApprove.maxAdditions, 50)
        XCTAssertEqual(loaded.resolve(owner: "acme", repo: "docs").autoApprove.maxAnnotationSeverity, .info)
        XCTAssertEqual(loaded.resolve(owner: "acme", repo: "other").splitMode, .single)
    }

    func testConversionRefusesWhatItCantKeep() throws {
        XCTAssertThrowsError(try RulesConvert.convert(
            configText: "version: 1\n", path: "p", rules: [:], rulesRoot: "/r", repositories: [])) {
            XCTAssertEqual($0 as? RulesConvert.Error, .nothingToConvert)
        }
        XCTAssertThrowsError(try RulesConvert.convert(
            configText: Self.oldConfig, path: "p", rules: [RulesConvert.rulePath: "x"], rulesRoot: "/r", repositories: [])) {
            XCTAssertEqual($0 as? RulesConvert.Error, .exists(RulesConvert.rulePath))
        }
        // An existing configure rule that changes a converted setting.
        let other = """
            name: budgets
            rule:
              match:
                - output:
                    rule: cheap
                    max_cost_usd_per_subreview: 0.5
            """
        XCTAssertThrowsError(try RulesConvert.convert(
            configText: Self.oldConfig, path: "p", rules: ["configure/90-budgets.yaml": other], rulesRoot: "/r",
            repositories: [])) { error in
            guard case .differs(let lines)? = error as? RulesConvert.Error else { return XCTFail("\(error)") }
            XCTAssertTrue(lines.contains { $0.contains("acme/monorepo") }, "\(lines)")
        }
    }

    /// PRBar converts `repos:` itself when it loads the file, at launch
    /// and when the file changes, so nothing waits on the user.
    @MainActor
    func testReposAreConvertedWhenTheFileLoads() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prbar-auto-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("prbar.yaml")
        try ConfigFile.write(Self.oldConfig, to: file)

        let store = RepoConfigStore(fileURL: file, lastGoodURL: nil)
        XCTAssertFalse(store.needsConversion)
        XCTAssertNil(store.loadIssue)
        XCTAssertEqual(store.resolve(owner: "acme", repo: "monorepo").splitMode, .perSubfolder)
        XCTAssertTrue(store.resolve(owner: "acme", repo: "secret-x").excluded)
        XCTAssertTrue(store.warnings.first?.contains("Converted the 4 repos: entries") == true, "\(store.warnings)")
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("repos:"))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("prbar.yaml.before-rules"), encoding: .utf8),
                       Self.oldConfig)

        // A `repos:` written back later, by an older PRBar say, converts too.
        try FileManager.default.moveItem(
            at: dir.appendingPathComponent("rules/configure/50-repos.yaml"),
            to: dir.appendingPathComponent("50-repos.yaml.aside"))
        try ConfigFile.write(Self.oldConfig, to: file)
        store.reloadIfChanged()
        XCTAssertFalse(store.needsConversion, store.loadIssue ?? "")
        XCTAssertEqual(store.resolve(owner: "acme", repo: "docs").autoApprove.maxAdditions, 50)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("prbar.yaml.before-rules-2").path))
    }

    /// When the conversion can't keep every setting, nothing runs: the
    /// settings in effect are the shipped defaults, and a review on the
    /// wrong budget and split costs money even when nothing is posted.
    @MainActor
    func testAConversionThatWouldChangeSettingsWaitsAndReviewsNothing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prbar-refused-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("prbar.yaml")
        try ConfigFile.write(Self.oldConfig, to: file)
        let rules = dir.appendingPathComponent("rules/configure")
        try FileManager.default.createDirectory(at: rules, withIntermediateDirectories: true)
        try """
            name: budgets
            rule:
              match:
                - output: {rule: cheap, max_cost_usd_per_subreview: 0.5}
            """.write(to: rules.appendingPathComponent("90-budgets.yaml"), atomically: true, encoding: .utf8)

        let store = RepoConfigStore(fileURL: file, lastGoodURL: nil)
        XCTAssertTrue(store.needsConversion)
        XCTAssertTrue(store.loadIssue?.contains("acme/monorepo") == true, store.loadIssue ?? "")
        XCTAssertFalse(store.resolve(owner: "acme", repo: "monorepo").aiReviewEnabled)
        XCTAssertFalse(store.resolve(owner: "acme", repo: "other").autoApprove.enabled)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), Self.oldConfig, "untouched")
    }

    // MARK: - The stage

    func testFilesMergeInOrderAndTheRepositoryListsApply() throws {
        let rules = try XCTUnwrap(try RuleDirectory.compile([
            "lists.yaml": "big: [acme/monorepo]\n",
            "configure/10-acme.yaml": """
                name: acme
                rule:
                  match:
                    - condition: repo.owner == "acme"
                      output:
                        rule: acme
                        provider: codex
                        max_cost_usd_per_subreview: 2
                        auto_approve:
                          enabled: true
                          min_confidence: 0.9
                """,
            "configure/20-big.yaml": """
                name: big
                rule:
                  match:
                    - condition: repo.full_name in lists.big
                      output: {rule: big, max_cost_usd_per_subreview: 5, root_patterns: [services/*/]}
                """,
        ], root: "/r"))
        var config = PRBarConfig()
        config.compiledRules = rules
        config.repositories = RepositoryScope(triage: ["acme/*", "!acme/legacy"], hide: ["acme/archive"], trustRules: ["acme/monorepo"])

        let configured = config.configured(owner: "acme", repo: "monorepo")
        XCTAssertEqual(configured.rules, ["acme", "big"])
        let monorepo = config.resolve(owner: "acme", repo: "monorepo")
        XCTAssertEqual(monorepo.providerOverride, .codex)
        XCTAssertEqual(monorepo.maxCostUsdPerSubreview, 5, "the later file wins the field")
        XCTAssertEqual(monorepo.rootPatterns, ["services/*/"])
        XCTAssertEqual(monorepo.autoApprove.minConfidence, 0.9)
        XCTAssertEqual(monorepo.autoApprove.maxAdditions, AutoApproveConfig().maxAdditions, "a block replaces as a whole")
        XCTAssertTrue(monorepo.trustRepoRules)
        XCTAssertTrue(monorepo.aiReviewEnabled)

        XCTAssertFalse(config.resolve(owner: "acme", repo: "legacy").aiReviewEnabled, "outside triage")
        XCTAssertTrue(config.resolve(owner: "acme", repo: "archive").excluded)
        XCTAssertFalse(config.resolve(owner: "other", repo: "x").aiReviewEnabled)
        XCTAssertEqual(config.resolve(owner: "other", repo: "x").maxCostUsdPerSubreview, ReviewDefaults().maxCostUsdPerSubreview)
    }

    func testAConfigureRuleThatFailsTurnsPostingOff() throws {
        let rules = try XCTUnwrap(try RuleDirectory.compile([
            "configure/10-x.yaml": """
                name: x
                rule:
                  match:
                    - condition: lists.missing.size() > 0
                      output: {rule: x, provider: codex}
                """,
        ], root: "/r"))
        var config = PRBarConfig()
        config.defaults.autoApprove = AutoApproveConfig(enabled: true)
        config.defaults.shareFindings = .allFindings
        config.compiledRules = rules
        let configured = config.configured(owner: "o", repo: "r")
        XCTAssertNotNil(configured.error)
        let resolved = config.resolve(owner: "o", repo: "r")
        XCTAssertFalse(resolved.autoApprove.enabled)
        XCTAssertEqual(resolved.shareFindings, .off)
    }

    func testOutputsAreCheckedWithTheirPositions() {
        func compile(_ output: String) throws {
            _ = try RuleDirectory.compile(["configure/1.yaml": """
                name: x
                rule:
                  match:
                    - output:
                \(output)
                """], root: "/r")
        }
        XCTAssertNoThrow(try compile("        rule: ok\n        exclude_title_patterns: []\n        auto_approve: {}"))
        XCTAssertThrowsError(try compile("        rule: x\n        split_mode: per_subfolder")) {
            XCTAssertTrue($0.localizedDescription.contains("one of perSubfolder, single"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try compile("        rule: x\n        auto_approve:\n          enable: true")) {
            XCTAssertTrue($0.localizedDescription.contains("'enable' is not a field of 'auto_approve'"), $0.localizedDescription)
            XCTAssertTrue($0.localizedDescription.contains("1.yaml:7:11"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try compile("        rule: x\n        root_patterns: kernel/")) {
            XCTAssertTrue($0.localizedDescription.contains("is a list"), $0.localizedDescription)
        }
    }

    func testTheSchemaCoversTheOutput() throws {
        let schema = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(RuleSchema.json(.configure).utf8)) as? [String: Any])
        let output = try XCTUnwrap((schema["definitions"] as? [String: Any])?["output"] as? [String: Any])
        let properties = try XCTUnwrap(output["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), Set(RuleOutputs.configure.map(\.name)))
        let approve = try XCTUnwrap(properties["auto_approve"] as? [String: Any])
        XCTAssertEqual(Set((approve["properties"] as? [String: Any])?.keys.map { $0 } ?? []), Set(RuleOutputs.autoApprove.map(\.name)))
    }
}
