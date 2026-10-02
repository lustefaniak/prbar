import XCTest
@testable import PRBarCore

/// Writing rules without knowing them by heart: the catalog of facts,
/// completion, colouring, examples and the builder.
final class RuleCatalogTests: XCTestCase {
    func testEveryFactIsDescribed() {
        for stage in RuleCatalog.Stage.allCases {
            let facts = RuleCatalog.facts(stage)
            XCTAssertFalse(facts.isEmpty, stage.rawValue)
            XCTAssertEqual(facts.filter { $0.help.isEmpty }.map(\.path), [], "\(stage.rawValue)")
        }
        XCTAssertTrue(RuleCatalog.facts(.decide).contains { $0.path == "review.max_severity" })
        XCTAssertFalse(RuleCatalog.facts(.select).contains { $0.path.hasPrefix("review") })
        XCTAssertEqual(RuleCatalog.facts(.configure).map(\.path), ["repo", "repo.owner", "repo.name", "repo.full_name", "lists"])
    }

    private func complete(_ text: String, _ stage: RuleCatalog.Stage = .decide, lists: [String] = []) -> RuleCompletion.Result {
        RuleCompletion.complete(text, cursor: text.utf16.count, stage: stage, lists: lists)
    }

    private let head = "name: x\nrule:\n  match:\n"

    func testConditionsCompleteFactsFieldsListsAndMethods() {
        var result = complete(head + "    - condition: pr.add")
        XCTAssertEqual(result.items.map(\.insert), ["additions"])
        XCTAssertEqual(result.tokenStart, (head + "    - condition: pr.").utf16.count, "replaces only what follows the dot")

        result = complete(head + "    - condition: pr.author in lists.", lists: ["trusted", "bots"])
        XCTAssertEqual(result.items.map(\.insert), ["trusted", "bots"])

        result = complete(head + "    - condition: review.max_severity >= severity.w")
        XCTAssertEqual(result.items.map(\.insert), ["warning"])

        result = complete(head + "    - condition: pr.title.st")
        XCTAssertEqual(result.items.map(\.insert), ["startsWith("])

        result = complete(head + "    - condition: to")
        XCTAssertTrue(result.items.contains { $0.insert == "touches(" }, "\(result.items.map(\.insert))")

        result = complete(head + "    - condition: rev", .select)
        XCTAssertFalse(result.items.contains { $0.insert == "review" }, "no review in select")
    }

    func testOutputsCompleteFieldsAndValues() {
        let output = head + "    - condition: pr.draft\n      output:\n"
        var result = complete(output + "        act")
        XCTAssertEqual(result.items.map(\.insert), ["action: "])

        result = complete(output + "        action: re", .decide)
        XCTAssertEqual(result.items.map(\.insert), ["request_changes"])

        result = complete(output + "        rule: x\n        auto_approve:\n          max_add", .configure)
        XCTAssertEqual(result.items.map(\.insert), ["max_additions: "], "a nested block's own fields")

        result = complete(output + "        split_mode: ", .configure)
        XCTAssertEqual(Set(result.items.map(\.insert)), ["perSubfolder", "single"])
    }

    func testColours() {
        let text = "# a comment\n    - condition: pr.author in lists.trusted && glob(pr.repo, \"acme/*\") && pr.additions < 10\n"
        let spans = RuleHighlighter.spans(text)
        func kind(of word: String) -> RuleHighlighter.Kind? {
            let range = (text as NSString).range(of: word)
            return spans.first { $0.location == range.location && $0.length == range.length }?.kind
        }
        XCTAssertEqual(kind(of: "# a comment"), .comment)
        XCTAssertEqual(kind(of: "condition"), .key)
        XCTAssertEqual(kind(of: "pr.author"), .fact)
        XCTAssertEqual(kind(of: "lists.trusted"), .fact)
        XCTAssertEqual(kind(of: "glob"), .function)
        XCTAssertEqual(kind(of: "\"acme/*\""), .string)
        XCTAssertEqual(kind(of: "10"), .number)
        XCTAssertEqual(kind(of: "in"), .keyword)
    }

    func testEveryExampleCompiles() throws {
        let examples = RuleExamples.all(repository: "acme/monorepo", viewer: "alice")
        XCTAssertEqual(Set(examples.map(\.stage)), Set(RuleCatalog.Stage.allCases))
        for example in examples {
            var lists = ""
            for (name, values) in example.lists { lists += "\(name): [\(values.joined(separator: ", "))]\n" }
            XCTAssertNoThrow(
                try RuleDirectory.compile([example.path: example.text, "lists.yaml": lists], root: "/r"), example.id)
        }
    }

    func testTheBuilderWritesRulesThatCompile() throws {
        var builder = RuleBuilder(stage: .decide, name: "Big from outsiders")
        builder.conditions = [
            .init(fact: "below.action", op: .equals, value: "approve"),
            .init(fact: "pr.author", op: .notInList, value: "trusted"),
            .init(fact: "pr.additions", op: .greater, value: "400"),
            .init(fact: "pr.files", op: .anyFile, value: "infra/**"),
            .init(fact: "pr.labels", op: .contains, value: "urgent"),
            .init(fact: "pr.age", op: .longer, value: "3 days"),
            .init(fact: "pr.draft", op: .isFalse),
        ]
        builder.outputs = ["action": "share", "min_severity": "warning"]
        XCTAssertEqual(builder.condition, #"(below.action == "approve") && (!(pr.author in lists.trusted)) && (pr.additions > 400) && (touches(pr.files, "infra/**")) && ("urgent" in pr.labels) && (pr.age > duration("72h")) && (!pr.draft)"#)
        let rules = try XCTUnwrap(try RuleDirectory.compile(["decide/50-x.yaml": builder.yaml, "lists.yaml": "trusted: [a]\n"], root: "/r"))
        XCTAssertEqual(rules.decide.count, 1)

        var configure = RuleBuilder(stage: .configure, name: "acme")
        configure.conditions = [.init(fact: "repo.full_name", op: .globs, value: "acme/*")]
        configure.outputs = ["split_mode": "perSubfolder", "root_patterns": "services/*/, lib/*/",
                             "auto_approve.enabled": "true", "auto_approve.max_additions": "100", "custom_system_prompt": "Be brief: it's fine."]
        var config = PRBarConfig()
        config.compiledRules = try RuleDirectory.compile(["configure/50-acme.yaml": configure.yaml], root: "/r")
        let resolved = config.resolve(owner: "acme", repo: "x")
        XCTAssertEqual(resolved.rootPatterns, ["services/*/", "lib/*/"])
        XCTAssertEqual(resolved.autoApprove.maxAdditions, 100)
        XCTAssertEqual(resolved.customSystemPrompt, "Be brief: it's fine.")
    }
}
