import XCTest
@testable import PRBarCore

/// A repository's own rules: a layer between the user's rules and the
/// settings, for repositories the user trusts.
@MainActor
final class RepoRulesTests: XCTestCase {
    nonisolated static let teamDecide = """
        name: team
        rule:
          match:
            - condition: review.verdict == "approve" && pr.author in lists.team
              output: {rule: team-approve, action: approve}
        """

    nonisolated static func repoFiles(tree: String = "t1", decide: String = teamDecide) -> RepoRuleFiles {
        RepoRuleFiles(tree: tree, files: ["decide/10-team.yaml": decide, "lists.yaml": "team: [a]\n"])
    }

    func pr(tree: String? = "t1") -> InboxPR {
        var pr = RuntimeFixtures.requestedPR()
        pr.repoRulesTree = tree
        return pr
    }

    func config(trust: Bool, personal: Rules? = nil, repo: Rules?) -> ResolvedRepoConfig {
        var rule = RepoConfig.default
        rule.trustRepoRules = trust
        return ResolvedRepoConfig(rule: rule, defaults: ReviewDefaults(), rules: personal, repoRules: repo)
    }

    func testTheRepositoryDecidesBetweenYourRulesAndTheSettings() async throws {
        let repo = try XCTUnwrap(try Self.repoFiles().compile(repo: "o/r"))
        XCTAssertEqual(repo.sources.map(\.path), ["o/r:.prbar/rules/decide/10-team.yaml"])
        XCTAssertEqual(repo.lists, ["team": ["a"]])
        let review = RulesTests.review(.approve)

        guard case .post(let approved) = AutoReviewPlan.plan(
            pr: pr(), review: review, config: config(trust: true, repo: repo), providerId: .claude, diffText: "")
        else { return XCTFail() }
        XCTAssertEqual(approved.action, .approve, "the team's rule approves")

        guard case .none = AutoReviewPlan.plan(
            pr: pr(), review: review, config: config(trust: false, repo: repo), providerId: .claude, diffText: "")
        else { return XCTFail("untrusted: the settings (off) decide") }

        // Yours sit on top and see the team's answer as `below`.
        let personal = try Rules.compile(select: [], decide: [.init(path: "mine.yaml", text: """
            name: mine
            rule:
              match:
                - condition: below.source == "repo" && below.rule == "team-approve" && pr.author in lists.originals
                  output: {rule: not-for-originals, action: share}
            """)], lists: ["originals": ["a"]])
        guard case .post(let shared) = AutoReviewPlan.plan(
            pr: pr(), review: RulesTests.review(.approve, [RulesTests.finding(.info)]),
            config: config(trust: true, personal: personal, repo: repo), providerId: .claude, diffText: "")
        else { return XCTFail() }
        XCTAssertEqual(shared.source, .sharedFindings)
    }

    func testRulesThatDontCompilePostNothingForThatRepository() async throws {
        XCTAssertThrowsError(try Self.repoFiles(decide: "name: x\nrule:\n  match:\n    - condition: nope.\n      output: {rule: x, action: none}\n").compile(repo: "o/r")) { error in
            XCTAssertTrue(error.localizedDescription.contains("o/r:.prbar/rules/decide/10-team.yaml"), error.localizedDescription)
        }
    }

    // MARK: - The worker

    actor Fetches {
        var count = 0
        var fail = false
        func fetch() throws -> Int {
            count += 1
            if fail { throw URLError(.timedOut) }
            return count
        }
        func failing(_ value: Bool) { fail = value }
    }

    func worker(_ fetches: Fetches, files: @escaping @Sendable () -> RepoRuleFiles?) -> ReviewQueueWorker {
        let worker = ReviewQueueWorker(diffFetcher: { _, _, _ in "" })
        worker.providerLookup = { _ in NeverProvider() }
        worker.configResolver = { _, _ in
            var rule = RepoConfig.default
            rule.trustRepoRules = true
            return ResolvedRepoConfig(rule: rule, defaults: ReviewDefaults())
        }
        worker.repoRulesFetcher = { _, _ in
            _ = try await fetches.fetch()
            return files()
        }
        return worker
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testTheWorkerFetchesOncePerTreeAndAppliesThem() async throws {
        let fetches = Fetches()
        let skipAll = RepoRuleFiles(tree: "t1", files: ["select/10.yaml": """
            name: s
            rule:
              match:
                - output: {rule: team-skip, action: skip, reason: the team reviews these by hand}
            """])
        let worker = worker(fetches) { skipAll }
        let pr = pr()
        worker.enqueueNewReviewRequests(from: [pr])
        XCTAssertNil(worker.reviews[pr.nodeId], "waiting for the repository's rules")
        try await waitFor { worker.reviews[pr.nodeId] != nil }
        guard case .skipped(.rule("team-skip", _))? = worker.reviews[pr.nodeId]?.status else {
            return XCTFail("\(String(describing: worker.reviews[pr.nodeId]))")
        }
        worker.enqueueNewReviewRequests(from: [pr])
        var count = await fetches.count
        XCTAssertEqual(count, 1, "kept for the tree")

        let moved = self.pr(tree: "t2")
        _ = await worker.layeredConfig(worker.configResolver("o", "r"), for: moved)
        count = await fetches.count
        XCTAssertEqual(count, 2, "a new tree is fetched again")

        let none = self.pr(tree: nil)
        XCTAssertNotNil(worker.cachedLayeredConfig(worker.configResolver("o", "r"), for: none), "no rules directory: nothing to fetch")
    }

    func testRulesThatCantBeFetchedPostNothing() async throws {
        let fetches = Fetches()
        await fetches.failing(true)
        let worker = worker(fetches) { Self.repoFiles() }
        worker.lazyRetryDelay = 0
        let layered = await worker.layeredConfig(worker.configResolver("o", "r"), for: pr())
        let count = await fetches.count
        XCTAssertEqual(count, 3, "tried three times")
        XCTAssertNotNil(layered.repoRules?.failure)
        XCTAssertNotNil(worker.repoRulesIssues["o/r"])
        guard case .none(let reason) = AutoReviewPlan.plan(
            pr: pr(), review: RulesTests.review(.approve), config: layered, providerId: .claude, diffText: "")
        else { return XCTFail() }
        XCTAssertTrue(reason.contains(Rules.unloadedRuleID), reason)
    }

    // MARK: - Fetching

    func testTheGraphQLResponseBecomesFiles() async throws {
        let json = #"""
            {"data": {"repository": {"object": {"oid": "abc", "entries": [
              {"name": "lists.yaml", "type": "blob", "object": {"text": "team: [a]\n", "isTruncated": false}},
              {"name": "decide", "type": "tree", "object": {"entries": [
                {"name": "10-team.yaml", "type": "blob", "object": {"text": "x", "isTruncated": false}},
                {"name": "big.yaml", "type": "blob", "object": {"text": null, "isTruncated": true}}
              ]}}
            ]}}}}
            """#
        let files = try XCTUnwrap(try JSONDecoder().decode(RepoRulesResponse.self, from: Data(json.utf8)).files)
        XCTAssertEqual(files.tree, "abc")
        XCTAssertEqual(files.files, ["lists.yaml": "team: [a]\n", "decide/10-team.yaml": "x"])
        XCTAssertEqual(files.truncated, ["decide/big.yaml"])
        XCTAssertThrowsError(try files.compile(repo: "o/r"), "a file too large to read refuses the rules")
        let missing = #"{"data": {"repository": {"object": null}}}"#
        XCTAssertNil(try JSONDecoder().decode(RepoRulesResponse.self, from: Data(missing.utf8)).files)
    }
}
