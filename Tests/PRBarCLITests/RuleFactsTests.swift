import XCTest
@testable import PRBarCore

/// The facts and functions rules can use, each through a real policy.
final class RuleFactsTests: XCTestCase {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func pr() -> InboxPR {
        var pr = RuntimeFixtures.requestedPR()
        pr.createdAt = now.addingTimeInterval(-4 * 86_400)
        pr.updatedAt = now.addingTimeInterval(-3_600)
        pr.authorAssociation = "FIRST_TIME_CONTRIBUTOR"
        pr.labels = ["dependencies", "security"]
        pr.requestedReviewers = ["me"]
        pr.requestedTeams = ["platform"]
        pr.humanReviews = [PRReviewSummary(author: "bob", state: "APPROVED", submittedAt: now, body: "", isFromViewer: false)]
        return pr
    }

    /// Whether `condition` holds in `stage` with these facts.
    func holds(_ condition: String, select facts: SelectFacts, file: StaticString = #filePath, line: UInt = #line) throws -> Bool {
        let rules = try Rules.compile(select: [.init(path: "t.yaml", text: Self.policy(condition))], decide: [])
        return try rules.select(facts) != nil
    }

    func holds(_ condition: String, decide facts: DecideFacts) throws -> Bool {
        let rules = try Rules.compile(select: [], decide: [.init(path: "t.yaml", text: Self.policy(condition, decide: true))])
        return try rules.decide(facts) != nil
    }

    static func policy(_ condition: String, decide: Bool = false) -> String {
        let output = decide ? #"{"rule": "x", "action": "none"}"# : #"{"rule": "x", "action": "skip"}"#
        return """
            name: t
            rule:
              match:
                - condition: '\(condition.replacingOccurrences(of: "'", with: "''"))'
                  output: '\(output)'
            """
    }

    func selectFacts(_ pr: InboxPR = pr(), lazy: LazyFactValues = LazyFactValues()) -> SelectFacts {
        let rules = Rules.unloaded("")
        return ReviewAdmission.selectFacts(pr: pr, rules: rules, trigger: .reviewRequested, lazy: lazy, now: Self.now)
    }

    func testPRFacts() throws {
        let facts = selectFacts()
        for condition in [
            #""security" in pr.labels"#,
            #"pr.author_association == "FIRST_TIME_CONTRIBUTOR""#,
            #"!pr.author_is_bot"#,
            #""platform" in pr.requested_teams && "me" in pr.requested_reviewers"#,
            #"pr.reviews.exists(r, r.state == "approved" && r.author == "bob" && !r.by_viewer)"#,
            #"has(pr.created_at) && pr.age > duration("72h") && pr.idle < duration("2h")"#,
            #"now - pr.created_at > duration("96h") - duration("1s")"#,
            #"pr.checks_state == "none" && size(pr.checks) == 0"#,
            #"!has(pr.files) || size(pr.files) >= 0"#,
        ] {
            XCTAssertTrue(try holds(condition, select: facts), condition)
        }
    }

    func testChecks() throws {
        var pr = Self.pr()
        pr = InboxPR(pr, checks: [
            CheckSummary(typename: "CheckRun", name: "build", conclusion: "SUCCESS", status: "COMPLETED", url: nil),
            CheckSummary(typename: "CheckRun", name: "lint", conclusion: "FAILURE", status: "COMPLETED", url: nil),
        ])
        let facts = selectFacts(pr)
        XCTAssertTrue(try holds(#"pr.checks_state == "failed" && pr.checks.exists(c, c.name == "lint" && c.state == "failed")"#, select: facts))
    }

    func testFunctions() throws {
        let facts = selectFacts()
        for condition in [
            #"pr.title.upperAscii() == "T""#,
            #"pr.labels.sort() == ["dependencies", "security"]"#,
            #"sets.contains(pr.labels, ["security"])"#,
            #"math.greatest(pr.additions, 5) == 5"#,
            #"pr.repo.matches("^o/r$")"#,
            #"glob("docs/a/b.md", "docs/**")"#,
        ] {
            XCTAssertTrue(try holds(condition, select: facts), condition)
        }
    }

    func testFilesFromADiffCarryTheRiskBriefsReading() throws {
        let diff = """
            diff --git a/auth/token.go b/auth/token.go
            --- a/auth/token.go
            +++ b/auth/token.go
            @@ -1,1 +1,2 @@
             a
            +b
            diff --git a/docs/readme.md b/docs/readme.md
            --- a/docs/readme.md
            +++ b/docs/readme.md
            @@ -1,1 +1,1 @@
            -x
            +y

            """
        let files = FileFacts.list(diff: diff)
        XCTAssertEqual(files.map(\.path), ["auth/token.go", "docs/readme.md"])
        XCTAssertEqual(files.map(\.kind), ["source", "docs"])
        XCTAssertEqual(files.map(\.sensitive), [true, false])
        XCTAssertEqual(files[1].additions, 1)
        XCTAssertEqual(files[1].deletions, 1)
        XCTAssertGreaterThan(files[0].risk, files[1].risk)

        let review = RulesTests.review(.requestChanges, [
            DiffAnnotation(path: "auth/token.go", lineStart: 2, lineEnd: 2, severity: .warning, title: "leak", body: "Logs the SQL injection payload."),
        ])
        let rules = try Rules.compile(select: [], decide: [])
        let facts = AutoReviewPlan.decideFacts(
            pr: Self.pr(), review: review, providerId: .claude, diffText: diff,
            prior: [PriorReview(headSha: "old", aggregated: RulesTests.review(.requestChanges, [RulesTests.finding(.blocker)]))],
            lazy: LazyFactValues(), rules: rules, now: Self.now)
        for condition in [
            #"touches(pr.files, "auth/**") && !only(pr.files, "docs/**")"#,
            #"pr.files.exists(f, f.sensitive && f.kind == "source")"#,
            #"review.findings.exists(f, f.body.contains("SQL"))"#,
            #"review.prior.exists(p, p.max_severity == severity.blocker) && review.max_severity < severity.blocker"#,
            #"size(review.subreviews) == 0"#,
        ] {
            XCTAssertTrue(try holds(condition, decide: facts), condition)
        }
    }

    func testOnlyIsFalseWithoutFiles() throws {
        var facts = selectFacts(lazy: LazyFactValues(files: [], fetched: [.files]))
        XCTAssertFalse(try holds(#"only(pr.files, "docs/**")"#, select: facts))
        facts = selectFacts(lazy: LazyFactValues(files: nil, fetched: [.files]))
        XCTAssertFalse(try holds(#"only(pr.files, "docs/**") || touches(pr.files, "docs/**")"#, select: facts), "a failed fetch matches nothing")
        XCTAssertTrue(try holds(#"!has(pr.files)"#, select: facts))
    }

    // MARK: - Lazy facts

    func testARuleThatReadsFilesWaitsForThemAndOneThatDoesntDecidesAtOnce() throws {
        let rules = try Rules.compile(select: [.init(path: "t.yaml", text: """
            name: t
            rule:
              match:
                - condition: pr.draft
                  output: '{"rule": "drafts", "action": "skip"}'
                - condition: only(pr.files, "docs/**")
                  output: '{"rule": "docs", "action": "skip"}'
            """)], decide: [])
        let config = ResolvedRepoConfig(rule: RepoConfig.default, defaults: ReviewDefaults(), rules: rules)

        let draft = RuntimeFixtures.requestedPR(isDraft: true)
        XCTAssertEqual(ReviewAdmission.evaluate(pr: draft, config: config, existing: nil), .skip(.rule("drafts", reason: nil)),
                       "decided before the files are needed")
        let pr = RuntimeFixtures.requestedPR()
        XCTAssertEqual(ReviewAdmission.evaluate(pr: pr, config: config, existing: nil), .needs([.files]))
        let docs = LazyFactValues(files: FileFacts.list([("docs/a.md", 1, 0)]), fetched: [.files])
        XCTAssertEqual(ReviewAdmission.evaluate(pr: pr, config: config, existing: nil, lazy: docs), .skip(.rule("docs", reason: nil)))
        let code = LazyFactValues(files: FileFacts.list([("main.go", 1, 0)]), fetched: [.files])
        XCTAssertEqual(ReviewAdmission.evaluate(pr: pr, config: config, existing: nil, lazy: code), .review)
    }

    func testDecideWaitsForCommitters() throws {
        let rules = try Rules.compile(select: [], decide: [.init(path: "t.yaml", text: """
            name: t
            rule:
              match:
                - condition: pr.committers.all(c, c in lists.trusted)
                  output: '{"rule": "trusted", "action": "approve"}'
            """)], lists: ["trusted": ["a"]])
        let config = ResolvedRepoConfig(rule: RepoConfig.default, defaults: ReviewDefaults(), rules: rules)
        let pr = RuntimeFixtures.requestedPR()
        let review = RulesTests.review(.approve)
        guard case .needs(let facts) = AutoReviewPlan.plan(pr: pr, review: review, config: config, providerId: .claude, diffText: "")
        else { return XCTFail() }
        XCTAssertEqual(facts, [.committers])
        let known = LazyFactValues(committers: ["a"], fetched: [.committers])
        guard case .post(let staged) = AutoReviewPlan.plan(
            pr: pr, review: review, config: config, providerId: .claude, diffText: "", lazy: known)
        else { return XCTFail() }
        XCTAssertEqual(staged.action, .approve)
    }
}

/// The worker fetches what a select rule needs, once, then decides.
@MainActor
final class LazyRuleFactTests: XCTestCase {
    actor Calls {
        var diffs = 0
        var committers = 0
        func diff() { diffs += 1 }
        func committer() -> Int {
            committers += 1
            return committers
        }
    }

    static let docsDiff = """
        diff --git a/docs/a.md b/docs/a.md
        --- a/docs/a.md
        +++ b/docs/a.md
        @@ -1,1 +1,1 @@
        -x
        +y

        """

    func worker(rules: Rules, calls: Calls, diff: String = docsDiff) -> ReviewQueueWorker {
        let worker = ReviewQueueWorker(diffFetcher: { _, _, _ in
            await calls.diff()
            return diff
        })
        worker.providerLookup = { _ in NeverProvider() }
        worker.configResolver = { _, _ in ResolvedRepoConfig(rule: RepoConfig.default, defaults: ReviewDefaults(), rules: rules) }
        return worker
    }

    static func rules(_ condition: String, _ action: String = "skip") throws -> Rules {
        try Rules.compile(select: [.init(path: "t.yaml", text: """
            name: t
            rule:
              match:
                - condition: \(condition)
                  output: '{"rule": "r", "action": "\(action)", "reason": "because"}'
            """)], decide: [])
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testFilesComeFromTheDiffOnceAndTheRuleSkips() async throws {
        let calls = Calls()
        let worker = worker(rules: try Self.rules(#"only(pr.files, "docs/**")"#), calls: calls)
        let pr = RuntimeFixtures.requestedPR()
        worker.enqueueNewReviewRequests(from: [pr])
        worker.enqueueNewReviewRequests(from: [pr])
        XCTAssertNil(worker.reviews[pr.nodeId], "nothing recorded while the diff is fetched")
        try await waitFor { worker.reviews[pr.nodeId] != nil }
        guard case .skipped(.rule("r", "because"))? = worker.reviews[pr.nodeId]?.status else {
            return XCTFail("\(String(describing: worker.reviews[pr.nodeId]))")
        }
        worker.enqueueNewReviewRequests(from: [pr])
        let diffs = await calls.diffs
        XCTAssertEqual(diffs, 1, "kept for this head commit")
    }

    func testTheReviewReusesTheDiffTheRuleFetched() async throws {
        let calls = Calls()
        let worker = worker(rules: try Self.rules(#"touches(pr.files, "src/**")"#), calls: calls)
        let pr = RuntimeFixtures.requestedPR()
        worker.enqueueNewReviewRequests(from: [pr])
        try await waitFor {
            if case .running? = worker.reviews[pr.nodeId]?.status { return true }
            return false
        }
        try await Task.sleep(for: .milliseconds(50))
        let diffs = await calls.diffs
        XCTAssertEqual(diffs, 1, "the run took the diff the rule fetched")
    }

    func testAFailedFetchHoldsThePRBackAndTriesAgainLater() async throws {
        let calls = Calls()
        let worker = worker(rules: try Self.rules(#"pr.committers.exists(c, c == "a")"#), calls: calls)
        worker.lazyRetryDelay = 0
        worker.lazyFactFetcher = LazyFactFetcher(committers: { _, _, _ in
            if await calls.committer() < 2 { throw URLError(.timedOut) }
            return ["a"]
        })
        let pr = RuntimeFixtures.requestedPR()
        worker.enqueueNewReviewRequests(from: [pr])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(worker.reviews[pr.nodeId], "not decided on a fact that failed to arrive")
        worker.enqueueNewReviewRequests(from: [pr])
        try await waitFor { worker.reviews[pr.nodeId] != nil }
        guard case .skipped(.rule("r", _))? = worker.reviews[pr.nodeId]?.status else {
            return XCTFail("\(String(describing: worker.reviews[pr.nodeId]))")
        }
    }

    func testAFactThatKeepsFailingIsGivenUpOn() async throws {
        let calls = Calls()
        let worker = worker(rules: try Self.rules(#"has(pr.committers)"#), calls: calls)
        worker.lazyRetryDelay = 0
        worker.lazyFactFetcher = LazyFactFetcher(committers: { _, _, _ in
            _ = await calls.committer()
            throw URLError(.timedOut)
        })
        let pr = RuntimeFixtures.requestedPR()
        for _ in 0..<3 {
            worker.enqueueNewReviewRequests(from: [pr])
            try await Task.sleep(for: .milliseconds(50))
        }
        try await waitFor { worker.reviews[pr.nodeId] != nil }
        let tries = await calls.committers
        XCTAssertEqual(tries, 3)
        // has() is false without them, so the rule doesn't skip: reviewed.
        XCTAssertNotNil(worker.reviews[pr.nodeId])
        if case .skipped? = worker.reviews[pr.nodeId]?.status { XCTFail("decided as if the committers were known") }
    }
}

private extension InboxPR {
    init(_ pr: InboxPR, checks: [CheckSummary]) {
        self.init(
            nodeId: pr.nodeId, owner: pr.owner, repo: pr.repo, number: pr.number, title: pr.title, body: pr.body,
            url: pr.url, author: pr.author, headRef: pr.headRef, baseRef: pr.baseRef, headSha: pr.headSha,
            isDraft: pr.isDraft, role: pr.role, mergeable: pr.mergeable, mergeStateStatus: pr.mergeStateStatus,
            reviewDecision: pr.reviewDecision, checkRollupState: "FAILURE",
            totalAdditions: pr.totalAdditions, totalDeletions: pr.totalDeletions, changedFiles: pr.changedFiles,
            hasAutoMerge: pr.hasAutoMerge, autoMergeEnabledBy: pr.autoMergeEnabledBy,
            allCheckSummaries: checks, allowedMergeMethods: pr.allowedMergeMethods,
            autoMergeAllowed: pr.autoMergeAllowed, deleteBranchOnMerge: pr.deleteBranchOnMerge)
        createdAt = pr.createdAt
        updatedAt = pr.updatedAt
    }
}
