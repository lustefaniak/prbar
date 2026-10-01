import XCTest
@testable import PRBarCore

/// The rules directory on disk, and the two places its rules decide.
@MainActor
final class RuleDirectoryTests: XCTestCase {
    private var dir: URL!
    private var rules: URL { dir.appendingPathComponent("rules") }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("prbar-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rules, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = rules.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func selectPolicy(_ condition: String, _ rule: String, _ action: String = "skip") -> String {
        """
        name: select
        rule:
          match:
            - condition: \(condition)
              output: '{"rule": "\(rule)", "action": "\(action)"}'
        """
    }

    func testFilesRunInNameOrderAndListsLoad() async throws {
        try write("lists.yaml", "trusted: [alice]\n")
        try write("select/20-drafts.yaml", Self.selectPolicy("pr.draft", "later"))
        try write("select/10-trusted.yaml", Self.selectPolicy("pr.draft && pr.author in lists.trusted", "first", "review"))
        try write("select/README.md", "not a policy")
        let loaded = try XCTUnwrap(try RuleDirectory.load(rules))
        XCTAssertEqual(loaded.select.count, 2)
        XCTAssertEqual(loaded.lists, ["trusted": ["alice"]])

        var pr = ChangeFacts(RuntimeFixtures.requestedPR(isDraft: true))
        pr.author = "alice"
        let facts = SelectFacts(pr: pr, trigger: .reviewRequested, viewer: "me", lists: loaded.lists)
        XCTAssertEqual(try loaded.select(facts)?.rule, "first")
        var stranger = facts
        stranger.pr.author = "bob"
        XCTAssertEqual(try loaded.select(stranger)?.rule, "later")
    }

    func testNoPoliciesIsNoRules() async throws {
        try write("lists.yaml", "trusted: [alice]\n")
        XCTAssertNil(try RuleDirectory.load(rules))
        XCTAssertNil(try RuleDirectory.load(dir.appendingPathComponent("missing")))
    }

    func testABrokenPolicyNamesItsFile() async throws {
        try write("decide/10-x.yaml", """
            name: decide
            rule:
              match:
                - condition: review.confidense > 0.5
                  output: '{"rule": "x", "action": "none"}'
            """)
        XCTAssertThrowsError(try RuleDirectory.load(rules)) { error in
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("10-x.yaml:4:"), text)
            XCTAssertTrue(text.contains("confidense"), text)
        }
    }

    // MARK: - Reloading

    private func store() -> RepoConfigStore {
        RepoConfigStore(fileURL: dir.appendingPathComponent("prbar.yaml"), lastGoodURL: nil)
    }

    func testTheStoreReloadsRulesAndKeepsWorkingOnesWhenAnEditBreaksThem() async throws {
        let store = store()
        XCTAssertNil(store.config.compiledRules)
        var changes = 0
        store.onChange = { changes += 1 }

        try write("select/10.yaml", Self.selectPolicy("pr.draft", "drafts"))
        store.reloadIfChanged()
        XCTAssertEqual(store.config.compiledRules?.select.count, 1)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(store.resolve(owner: "o", repo: "r").rules?.select.count, 1, "resolvers hand the rules out")

        try write("select/10.yaml", Self.selectPolicy("pr.drafty", "drafts"))
        store.reloadIfChanged()
        XCTAssertEqual(store.config.compiledRules?.select.count, 1, "the working rules stay")
        XCTAssertTrue(store.rulesIssue?.contains("drafty") ?? false, String(describing: store.rulesIssue))
        XCTAssertEqual(changes, 1)

        try FileManager.default.removeItem(at: rules.appendingPathComponent("select/10.yaml"))
        store.reloadIfChanged()
        XCTAssertNil(store.config.compiledRules)
        XCTAssertNil(store.rulesIssue)
    }

    func testRulesBrokenAtLaunchPostNothing() async throws {
        try write("decide/10.yaml", "name: decide\nrule:\n  match:\n    - condition: nope.\n")
        let store = store()
        XCTAssertNotNil(store.rulesIssue)
        let config = store.resolve(owner: "o", repo: "r")
        let outcome = AutoReviewPlan.plan(
            pr: RuntimeFixtures.requestedPR(), review: RulesTests.review(.approve), config: approving(config),
            providerId: .claude, diffText: "")
        guard case .none(let reason) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(reason.contains(Rules.unloadedRuleID), reason)
    }

    /// The repo settings would approve this review on their own.
    private func approving(_ config: ResolvedRepoConfig) -> ResolvedRepoConfig {
        var rule = config.rule
        rule.autoApprove = AutoApproveConfig(enabled: true)
        return ResolvedRepoConfig(rule: rule, defaults: config.defaults, rules: config.rules)
    }

    // MARK: - Select

    func testSelectRulesComeBeforeTheRepoSettings() async throws {
        let rules = try RulesTests.rules(select: """
            name: select
            rule:
              match:
                - condition: pr.title == "skip me"
                  output: '{"rule": "named", "action": "skip", "reason": "asked to"}'
                - condition: pr.draft
                  output: '{"rule": "drafts-too", "action": "review"}'
            """, decide: nil)
        var defaults = ReviewDefaults()
        defaults.reviewDrafts = false
        let config = ResolvedRepoConfig(rule: RepoConfig.default, defaults: defaults, rules: rules)

        var pr = RuntimeFixtures.requestedPR()
        XCTAssertEqual(ReviewAdmission.evaluate(pr: pr, config: config, existing: nil), .review, "no match: the settings decide")

        pr = RuntimeFixtures.requestedPR(isDraft: true)
        XCTAssertEqual(ReviewAdmission.evaluate(pr: pr, config: config, existing: nil), .review, "the rule reviews a draft the settings skip")

        pr = InboxPR(copying: RuntimeFixtures.requestedPR(), title: "skip me")
        XCTAssertEqual(ReviewAdmission.evaluate(pr: pr, config: config, existing: nil), .skip(.rule("named", reason: "asked to")))
        XCTAssertEqual(ReviewAdmission.evaluate(pr: RuntimeFixtures.requestedPR(role: .authored), config: config, existing: nil), .ignore(.notRequested))
    }

    func testARuleSkipSurvivesTheStateFileAndOldReasonsStillRead() async throws {
        let rule = ReviewState.SkipReason.rule("named", reason: "asked to")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode([rule, .draftNotReviewed])
        XCTAssertEqual(String(data: data, encoding: .utf8), #"[{"reason":"asked to","rule":"named"},"draftNotReviewed"]"#)
        XCTAssertEqual(try JSONDecoder().decode([ReviewState.SkipReason].self, from: data), [rule, .draftNotReviewed])
    }

    // MARK: - Decide

    func testDecideRulesShapeWhatIsPosted() async throws {
        let rules = try RulesTests.rules(select: nil, decide: """
            name: decide
            rule:
              match:
                - condition: review.verdict == "approve"
                  output: '{"rule": "approve", "action": "approve", "attribution": true}'
                - condition: review.verdict == "abstain"
                  output: '{"rule": "quiet", "action": "none"}'
                - condition: size(review.findings) > 0
                  output: '{"rule": "share", "action": "share", "min_severity": severity.warning, "max_comments": 1}'
            """)
        let config = ResolvedRepoConfig(rule: RepoConfig.default, defaults: ReviewDefaults(), rules: rules)
        let pr = RuntimeFixtures.requestedPR()
        func plan(_ review: AggregatedReview) -> AutoReviewPlan.Outcome {
            AutoReviewPlan.plan(pr: pr, review: review, config: config, providerId: .claude, diffText: Self.diff)
        }

        guard case .post(let approve) = plan(RulesTests.review(.approve)) else { return XCTFail() }
        XCTAssertEqual(approve.action, .approve)
        XCTAssertTrue(approve.body.hasPrefix("Auto-approved by PRBar"), approve.body)

        guard case .none = plan(RulesTests.review(.abstain)) else { return XCTFail() }

        let findings = [
            DiffAnnotation(path: "a.swift", lineStart: 1, lineEnd: 1, severity: .suggestion, title: "minor", body: "b"),
            DiffAnnotation(path: "a.swift", lineStart: 2, lineEnd: 2, severity: .blocker, title: "worst", body: "b"),
            DiffAnnotation(path: "a.swift", lineStart: 3, lineEnd: 3, severity: .warning, title: "bad", body: "b"),
        ]
        guard case .post(let share) = plan(RulesTests.review(.requestChanges, findings)) else { return XCTFail() }
        XCTAssertEqual(share.source, .sharedFindings)
        XCTAssertEqual(share.comments.count, 1, "capped at one, the worst kept")
        XCTAssertTrue(share.comments.first?.body.contains("worst") ?? false, "\(share.comments)")
        XCTAssertEqual(share.body, "")

        let onlyMinor = [findings[0]]
        guard case .none(let reason) = plan(RulesTests.review(.requestChanges, onlyMinor)) else { return XCTFail() }
        XCTAssertTrue(reason.contains("no findings to share"), reason)
    }

    func testWithNoMatchingDecideRuleTheSettingsDecide() async throws {
        let rules = try RulesTests.rules(select: nil, decide: """
            name: decide
            rule:
              match:
                - condition: review.verdict == "abstain"
                  output: '{"rule": "quiet", "action": "none"}'
            """)
        var rule = RepoConfig.default
        rule.autoApprove = AutoApproveConfig(enabled: true)
        let config = ResolvedRepoConfig(rule: rule, defaults: ReviewDefaults(), rules: rules)
        let outcome = AutoReviewPlan.plan(
            pr: RuntimeFixtures.requestedPR(), review: RulesTests.review(.approve, confidence: 0.99),
            config: config, providerId: .claude, diffText: "")
        guard case .post(let staged) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(staged.action, .approve)
    }

    static let diff = """
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -0,0 +1,3 @@
        +one
        +two
        +three

        """
}

private extension InboxPR {
    init(copying pr: InboxPR, title: String) {
        self.init(
            nodeId: pr.nodeId, owner: pr.owner, repo: pr.repo, number: pr.number, title: title, body: pr.body,
            url: pr.url, author: pr.author, headRef: pr.headRef, baseRef: pr.baseRef, headSha: pr.headSha,
            isDraft: pr.isDraft, role: pr.role, mergeable: pr.mergeable, mergeStateStatus: pr.mergeStateStatus,
            reviewDecision: pr.reviewDecision, checkRollupState: pr.checkRollupState,
            totalAdditions: pr.totalAdditions, totalDeletions: pr.totalDeletions, changedFiles: pr.changedFiles,
            hasAutoMerge: pr.hasAutoMerge, autoMergeEnabledBy: pr.autoMergeEnabledBy,
            allCheckSummaries: pr.allCheckSummaries, allowedMergeMethods: pr.allowedMergeMethods,
            autoMergeAllowed: pr.autoMergeAllowed, deleteBranchOnMerge: pr.deleteBranchOnMerge)
    }
}
