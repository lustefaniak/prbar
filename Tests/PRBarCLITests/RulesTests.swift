import XCTest
@testable import PRBarCore

final class RulesTests: XCTestCase {
    static let select = """
        name: select
        rule:
          match:
            - condition: 'pr.title.startsWith("chore: bump ")'
              output: '{"rule": "skip-bumps", "action": "skip", "reason": "dependency bump"}'
            - condition: pr.draft && !(pr.author in lists.trusted)
              output: '{"rule": "skip-drafts", "action": "skip"}'
        """

    static let decide = """
        name: decide
        rule:
          match:
            - condition: >-
                pr.author in lists.trusted && review.verdict == "approve"
                && review.confidence >= 0.85 && review.max_severity <= severity.suggestion
                && pr.additions <= 200
              output: '{"rule": "trusted-approve", "action": "approve"}'
            - condition: review.findings.exists(f, f.severity >= severity.blocker && glob(f.path, "Sources/**"))
              output: '{"rule": "flag-blockers", "action": "flag"}'
            - condition: review.confidence >= 0.5
              output: '{"rule": "share", "action": "share", "min_severity": severity.warning, "max_comments": 5}'
        """

    static func rules(select: String? = select, decide: String? = decide) throws -> Rules {
        try Rules.compile(
            select: select.map { [.init(path: "select.yaml", text: $0)] } ?? [],
            decide: decide.map { [.init(path: "decide.yaml", text: $0)] } ?? [],
            lists: ["trusted": ["alice"]])
    }

    static func selectFacts(_ pr: InboxPR) -> SelectFacts {
        SelectFacts(pr: ChangeFacts(pr, now: Date()), trigger: .reviewRequested, viewer: "me", lists: ["trusted": ["alice"]], now: Date())
    }

    static func decideFacts(_ pr: InboxPR, _ review: AggregatedReview) -> DecideFacts {
        DecideFacts(pr: ChangeFacts(pr, now: Date()), review: ReviewFacts(review, provider: .claude), viewer: "me", lists: ["trusted": ["alice"]], now: Date())
    }

    static func review(
        _ verdict: ReviewVerdict, confidence: Double = 0.9, _ annotations: [DiffAnnotation] = []
    ) -> AggregatedReview {
        AggregatedReview(
            verdict: verdict, confidence: confidence, summaryMarkdown: "s", annotations: annotations,
            costUsd: 0.1, toolCallCount: 0, toolNamesUsed: [], perSubreview: [], isSubscriptionAuth: false)
    }

    static func finding(_ severity: AnnotationSeverity, _ path: String = "Sources/a.swift") -> DiffAnnotation {
        DiffAnnotation(path: path, lineStart: 1, lineEnd: 1, severity: severity, title: "x", body: "y")
    }

    func testSelectFirstMatchAndFallThrough() throws {
        let rules = try Self.rules()
        var pr = RuntimeFixtures.requestedPR()
        XCTAssertNil(try rules.select(Self.selectFacts(pr)), "no match falls through to the repo settings")

        pr = RuntimeFixtures.requestedPR(isDraft: true)
        XCTAssertEqual(try rules.select(Self.selectFacts(pr)), RuleSelection(rule: "skip-drafts", action: .skip))
    }

    func testDecide() throws {
        let rules = try Self.rules()
        let pr = RuntimeFixtures.requestedPR()
        var facts = Self.decideFacts(pr, Self.review(.approve))
        facts.pr.author = "alice"
        XCTAssertEqual(try rules.decide(facts)?.action, .approve)

        facts = Self.decideFacts(pr, Self.review(.requestChanges, [Self.finding(.blocker)]))
        XCTAssertEqual(try rules.decide(facts)?.rule, "flag-blockers")

        facts = Self.decideFacts(pr, Self.review(.requestChanges, [Self.finding(.blocker, "Tests/a.swift")]))
        XCTAssertEqual(
            try rules.decide(facts),
            RuleDecision(rule: "share", action: .share, minSeverity: .warning, maxComments: 5))

        facts = Self.decideFacts(pr, Self.review(.approve, confidence: 0.2))
        XCTAssertNil(try rules.decide(facts))
    }

    func testAMisspeltFactIsRefusedWithItsPosition() {
        let broken = Self.select.replacingOccurrences(of: "pr.draft", with: "pr.drafted")
        XCTAssertThrowsError(try Self.rules(select: broken)) { error in
            let text = String(describing: error)
            XCTAssertTrue(text.contains("select.yaml:6:"), text)
            XCTAssertTrue(text.contains("drafted"), text)
        }
    }

    func testAReviewFactInSelectIsRefused() {
        let broken = Self.select.replacingOccurrences(of: "pr.draft &&", with: "review.confidence > 0.5 &&")
        XCTAssertThrowsError(try Self.rules(select: broken)) { error in
            XCTAssertTrue(String(describing: error).contains("review"), String(describing: error))
        }
    }

    func testAnOutputOfTheWrongShapeIsRefused() {
        let broken = Self.decide.replacingOccurrences(of: #""action": "flag""#, with: #""acton": "flag""#)
        XCTAssertThrowsError(try Self.rules(decide: broken)) { error in
            XCTAssertTrue(String(describing: error).contains("acton"), String(describing: error))
        }
    }
}
