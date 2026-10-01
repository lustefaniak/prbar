import XCTest
@testable import PRBarCore

/// `below`: a rule adjusting what the settings would decide instead of
/// restating them.
final class RuleBelowTests: XCTestCase {
    /// Auto-approve in the settings, but only for the people on a list.
    func testApproveOnlyForTheOldestColleagues() throws {
        let rules = try Rules.compile(select: [], decide: [.init(path: "d.yaml", text: """
            name: approvals
            rule:
              match:
                - condition: below.action == "approve" && !(pr.author in lists.oldest)
                  output:
                    rule: approve-only-oldest
                    action: share
            """)], lists: ["oldest": ["alice"]])
        var settings = RepoConfig.default
        settings.autoApprove = AutoApproveConfig(enabled: true)
        let config = ResolvedRepoConfig(rule: settings, defaults: ReviewDefaults(), rules: rules)
        func plan(author: String, confidence: Double = 0.99) -> AutoReviewPlan.Outcome {
            var pr = RuntimeFixtures.requestedPR()
            pr = InboxPR(pr, author: author)
            let review = RulesTests.review(.approve, confidence: confidence, [RulesTests.finding(.suggestion)])
            return AutoReviewPlan.plan(pr: pr, review: review, config: config, providerId: .claude, diffText: "")
        }

        guard case .post(let approved) = plan(author: "alice") else { return XCTFail() }
        XCTAssertEqual(approved.action, .approve, "on the list: the settings approve")

        guard case .post(let shared) = plan(author: "mallory") else { return XCTFail() }
        XCTAssertEqual(shared.source, .sharedFindings, "off the list: the findings are shared instead")

        guard case .none(let reason) = plan(author: "mallory", confidence: 0.3) else { return XCTFail() }
        XCTAssertTrue(reason.contains("confidence"), "the settings wouldn't approve, so the rule doesn't match: \(reason)")
    }

    func testSelectSeesWhyTheSettingsSkip() throws {
        let rules = try Rules.compile(select: [.init(path: "s.yaml", text: """
            name: s
            rule:
              match:
                - condition: below.action == "skip" && below.reason.contains("draft") && pr.author in lists.vip
                  output: {rule: vip-drafts, action: review}
            """)], decide: [], lists: ["vip": ["a"]])
        var defaults = ReviewDefaults()
        defaults.reviewDrafts = false
        let config = ResolvedRepoConfig(rule: RepoConfig.default, defaults: defaults, rules: rules)
        let draft = RuntimeFixtures.requestedPR(isDraft: true)
        XCTAssertEqual(ReviewAdmission.evaluate(pr: draft, config: config, existing: nil), .review)
        let stranger = InboxPR(draft, author: "b")
        XCTAssertEqual(ReviewAdmission.evaluate(pr: stranger, config: config, existing: nil), .skip(.draftNotReviewed))
    }

    func testGlobOverAList() throws {
        let rules = try Rules.compile(select: [.init(path: "s.yaml", text: """
            name: s
            rule:
              match:
                - condition: glob(pr.repo, lists.mine)
                  output: {rule: mine, action: skip}
            """)], decide: [], lists: ["mine": ["o/*", "!o/r"]])
        let facts = ReviewAdmission.selectFacts(
            pr: RuntimeFixtures.requestedPR(), rules: rules, trigger: .reviewRequested, lazy: LazyFactValues(), now: Date())
        XCTAssertNil(try rules.select(facts), "o/r is excluded by the later pattern")
        var other = facts
        other.pr.repo = "o/other"
        XCTAssertEqual(try rules.select(other)?.rule, "mine")
    }

    func testRecordsFromBeforeBelowStillReplay() throws {
        let rules = try Rules.compile(select: [.init(path: "s.yaml", text: """
            name: s
            rule:
              match:
                - condition: pr.draft
                  output: {rule: drafts, action: skip}
            """)], decide: [])
        var record = RuleEvaluation(
            id: UUID(), at: Date(), stage: .select, repo: "o/r", number: 1, title: "t", headSha: "abc",
            select: RulesTests.selectFacts(RuntimeFixtures.requestedPR(isDraft: true)), decide: nil,
            rule: "drafts", outcome: "drafts: skip", rulesDigest: "x", ruleFiles: [], fetched: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any])
        var select = try XCTUnwrap(json["select"] as? [String: Any])
        select.removeValue(forKey: "below")
        json["select"] = select
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        record = try decoder.decode(RuleEvaluation.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(record.select?.below)
        XCTAssertFalse(RuleReplay.replay(record, rules: rules).changed)
    }
}

private extension InboxPR {
    init(_ pr: InboxPR, author: String) {
        self.init(
            nodeId: pr.nodeId, owner: pr.owner, repo: pr.repo, number: pr.number, title: pr.title, body: pr.body,
            url: pr.url, author: author, headRef: pr.headRef, baseRef: pr.baseRef, headSha: pr.headSha,
            isDraft: pr.isDraft, role: pr.role, mergeable: pr.mergeable, mergeStateStatus: pr.mergeStateStatus,
            reviewDecision: pr.reviewDecision, checkRollupState: pr.checkRollupState,
            totalAdditions: pr.totalAdditions, totalDeletions: pr.totalDeletions, changedFiles: pr.changedFiles,
            hasAutoMerge: pr.hasAutoMerge, autoMergeEnabledBy: pr.autoMergeEnabledBy,
            allCheckSummaries: pr.allCheckSummaries, allowedMergeMethods: pr.allowedMergeMethods,
            autoMergeAllowed: pr.autoMergeAllowed, deleteBranchOnMerge: pr.deleteBranchOnMerge)
    }
}
