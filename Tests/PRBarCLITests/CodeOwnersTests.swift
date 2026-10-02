import XCTest
@testable import PRBarCore

final class CodeOwnersTests: XCTestCase {
    /// GitHub's documented examples.
    func testPatterns() {
        let cases: [(String, String, Bool)] = [
            ("*", "a/b/c.go", true),
            ("*.js", "src/app.js", true),
            ("*.js", "src/app.ts", false),
            ("*.go", "main.go", true),
            ("/build/logs/", "build/logs/x/y.log", true),
            ("/build/logs/", "src/build/logs/y.log", false),
            ("docs/*", "docs/getting-started.md", true),
            ("docs/*", "docs/build-app/troubleshooting.md", false),
            ("apps/", "apps/x.go", true),
            ("apps/", "src/apps/x.go", true),
            ("/docs/", "docs/a/b.md", true),
            ("/docs/", "x/docs/a.md", false),
            ("**/logs", "deep/down/logs/a.txt", true),
            ("**/logs", "logs/a.txt", true),
            ("kernel-*/", "kernel-alerts/main.go", true),
            ("/scripts/", "scripts/run.sh", true),
            ("lib/foo.go", "lib/foo.go", true),
            ("lib/foo.go", "x/lib/foo.go", false),
            ("Makefile", "sub/Makefile", true),
        ]
        for (pattern, path, expected) in cases {
            XCTAssertEqual(CodeOwners.matches(pattern, path), expected, "\(pattern) vs \(path)")
        }
    }

    func testLastMatchingLineWinsAndAnEmptyLineUnowns() {
        let owners = CodeOwners("""
            # comment
            *            @everyone
            /fe-app/     @acme/frontend @lead   # trailing comment
            /fe-app/generated/
            """)
        let facts = owners.owners(
            of: ["go.mod", "fe-app/src/a.ts", "fe-app/generated/b.ts"],
            members: ["acme/frontend": ["ann", "Lead"]])
        XCTAssertEqual(facts[0], FileOwnersFacts(path: "go.mod", owners: ["everyone"], teams: [], pattern: "*"))
        XCTAssertEqual(facts[1].owners, ["ann", "Lead"], "team members, then users, each once")
        XCTAssertEqual(facts[1].teams, ["acme/frontend"])
        XCTAssertEqual(facts[2], FileOwnersFacts(path: "fe-app/generated/b.ts", owners: [], teams: [], pattern: "/fe-app/generated/"))
        XCTAssertEqual(owners.teams(for: ["fe-app/x"]), ["acme/frontend"])
    }

    func testNoFileOwnsNothing() {
        let facts = CodeOwners("").owners(of: ["a.go"], members: [:])
        XCTAssertEqual(facts, [FileOwnersFacts(path: "a.go", owners: [], teams: [], pattern: nil)])
    }

    static let ownerRule = """
        name: owner
        rule:
          match:
            - condition: >-
                below.action == "approve" || (review.max_severity <= severity.suggestion
                && pr.codeowners.all(f, pr.author in f.owners))
              output:
                rule: owner-approves
                action: approve
        """

    /// The rule waits for the fact, then decides on it.
    func testDecideWaitsForCodeOwners() throws {
        let rules = try Rules.compile(select: [], decide: [.init(path: "t.yaml", text: Self.ownerRule)])
        let config = ResolvedRepoConfig(rule: RepoConfig.default, defaults: ReviewDefaults(), rules: rules)
        let pr = RuntimeFixtures.requestedPR()
        let review = RulesTests.review(.comment, confidence: 0.5, [RulesTests.finding(.suggestion)])
        guard case .needs(let facts) = AutoReviewPlan.plan(pr: pr, review: review, config: config, providerId: .claude, diffText: "")
        else { return XCTFail() }
        XCTAssertEqual(facts, [.codeowners])

        let owned = LazyFactValues(
            codeowners: [FileOwnersFacts(path: "a.go", owners: [pr.author], teams: [], pattern: "*")], fetched: [.codeowners])
        guard case .post(let staged) = AutoReviewPlan.plan(
            pr: pr, review: review, config: config, providerId: .claude, diffText: "", lazy: owned)
        else { return XCTFail() }
        XCTAssertEqual(staged.action, .approve)

        let someoneElse = LazyFactValues(
            codeowners: [FileOwnersFacts(path: "a.go", owners: ["other"], teams: [], pattern: "*")], fetched: [.codeowners])
        guard case .none = AutoReviewPlan.plan(
            pr: pr, review: review, config: config, providerId: .claude, diffText: "", lazy: someoneElse)
        else { return XCTFail("approved a PR whose author owns nothing") }
    }
}

/// The worker fetches CODEOWNERS from the PR's base branch and expands
/// its teams.
@MainActor
final class CodeOwnersFetchTests: XCTestCase {
    actor Calls {
        var refs: [String] = []
        var teams: [String] = []
        func ref(_ ref: String) { refs.append(ref) }
        func team(_ team: String) { teams.append(team) }
    }

    func testOwnersComeFromTheBaseBranchWithTeamsExpanded() async throws {
        let calls = Calls()
        let diff = LazyRuleFactTests.docsDiff
        let worker = ReviewQueueWorker(diffFetcher: { _, _, _ in diff })
        worker.lazyFactFetcher = LazyFactFetcher(
            committers: { _, _, _ in [] },
            codeowners: { _, _, ref in
                await calls.ref(ref)
                return "/docs/ @acme/writers\n"
            },
            teamMembers: { org, team in
                await calls.team("\(org)/\(team)")
                return ["ann"]
            })
        let pr = RuntimeFixtures.requestedPR()
        let values = await worker.fetchLazyFacts(pr, [.codeowners])
        XCTAssertEqual(values.codeowners, [FileOwnersFacts(path: "docs/a.md", owners: ["ann"], teams: ["acme/writers"], pattern: "/docs/")])
        _ = await worker.fetchLazyFacts(pr, [.codeowners])
        let refs = await calls.refs
        let teams = await calls.teams
        XCTAssertEqual(refs, [pr.baseRef, pr.baseRef])
        XCTAssertEqual(teams, ["acme/writers"], "team members are kept")
    }
}
