import XCTest
@testable import PRBarCore

/// `output` written as plain YAML.
final class RuleOutputsTests: XCTestCase {
    func decide(_ text: String) throws -> Rules {
        try Rules.compile(select: [], decide: [.init(path: "d.yaml", text: text)])
    }

    func facts(_ verdict: ReviewVerdict = .requestChanges, findings: [DiffAnnotation] = []) -> DecideFacts {
        RulesTests.decideFacts(RuntimeFixtures.requestedPR(), RulesTests.review(verdict, findings))
    }

    func testABlockOutputDecidesLikeItsCELForm() throws {
        let rules = try decide("""
            name: share
            rule:
              match:
                - condition: review.confidence >= 0.5
                  output:
                    rule: share-warnings   # the id
                    # what to do
                    action: share
                    min_severity: warning
                    max_comments: 10
            """)
        XCTAssertEqual(
            try rules.decide(facts()),
            RuleDecision(rule: "share-warnings", action: .share, minSeverity: .warning, maxComments: 10))
    }

    func testFlowOutputsQuotesAndNestedRules() throws {
        let rules = try decide("""
            name: nested
            rule:
              match:
                - condition: pr.repo == "o/r"
                  rule:
                    match:
                      - condition: review.verdict == "approve"
                        output: {rule: "it's \\"fine\\"", action: approve, attribution: true}
                      - output:
                          rule: o'neil
                          action: flag
                          min_severity: severity.blocker
            """)
        XCTAssertEqual(try rules.decide(facts(.approve)), RuleDecision(rule: #"it's "fine""#, action: .approve, attribution: true))
        XCTAssertEqual(try rules.decide(facts()), RuleDecision(rule: "o'neil", action: .flag, minSeverity: .blocker))
    }

    func testPositionsAfterAnOutputStayRight() throws {
        XCTAssertThrowsError(try decide("""
            name: p
            rule:
              match:
                - condition: review.verdict == "abstain"
                  output:
                    rule: a
                    action: none
                - condition: review.nope
                  output:
                    rule: b
                    action: none
            """)) { error in
            XCTAssertTrue(String(describing: error).contains("d.yaml:8:"), String(describing: error))
        }
    }

    func testMistakesPointAtTheirLine() throws {
        func problem(_ output: String) -> String {
            do {
                _ = try decide("name: p\nrule:\n  match:\n    - condition: true\n      output:\n\(output)")
                return "no error"
            } catch {
                return String(describing: error)
            }
        }
        var text = problem("        rule: x\n        acton: share")
        XCTAssertTrue(text.contains("d.yaml:7:9: 'acton' is not an output field here (fields: rule, action, inline, min_severity, max_comments, attribution)"), text)
        text = problem("        rule: x\n        action: sahre")
        XCTAssertTrue(text.contains("d.yaml:7:17: 'action' is one of approve, request_changes, comment, share, flag, none, not 'sahre'"), text)
        text = problem("        rule: x")
        XCTAssertTrue(text.contains("d.yaml:5:7: the output needs 'action'"), text)
        text = problem("        rule: x\n        action: share\n        max_comments: lots")
        XCTAssertTrue(text.contains("'max_comments' is a whole number, not 'lots'"), text)
        text = problem("        rule: x\n        action: share\n        min_severity: high")
        XCTAssertTrue(text.contains("'min_severity' is one of info, suggestion, warning, blocker, not 'high'"), text)
    }

    func testSelectOutputs() throws {
        let rules = try Rules.compile(select: [.init(path: "s.yaml", text: """
            name: s
            rule:
              match:
                - condition: pr.draft
                  output:
                    rule: drafts
                    action: skip
                    reason: still a draft
            """)], decide: [])
        let facts = RulesTests.selectFacts(RuntimeFixtures.requestedPR(isDraft: true))
        XCTAssertEqual(try rules.select(facts), RuleSelection(rule: "drafts", action: .skip, reason: "still a draft"))
        XCTAssertThrowsError(try Rules.compile(select: [.init(path: "s.yaml", text: """
            name: s
            rule:
              match:
                - output: {rule: x, action: share}
            """)], decide: [])) { error in
            XCTAssertTrue(String(describing: error).contains("'action' is one of review, skip, not 'share'"), String(describing: error))
        }
    }
}
