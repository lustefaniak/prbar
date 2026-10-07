import XCTest
@testable import PRBarCore

/// The Rules tab: unsaved rules tried on a PR and on the recorded
/// decisions, and saved only when they load.
@MainActor
final class RulesWorkbenchTests: XCTestCase {
    private var dir: URL!
    private var socketURL: URL!

    nonisolated static let skipBots = """
        name: bots
        rule:
          match:
            - condition: pr.author in lists.bots && pr.additions < 10
              output: {rule: small-bot-changes, action: skip, reason: a small bot change}
        """

    override func setUp() async throws {
        dir = URL(fileURLWithPath: "/tmp/prbar-wb-\(UUID().uuidString.prefix(8))")
        socketURL = dir.appendingPathComponent("server.sock")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("rules"), withIntermediateDirectories: true)
        try write("lists.yaml", "bots: [a]\n")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = dir.appendingPathComponent("rules").appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String) -> String? {
        try? String(contentsOf: dir.appendingPathComponent("rules").appendingPathComponent(path), encoding: .utf8)
    }

    private func startServer() throws -> PRBarRuntime {
        let runtime = RuntimeFixtures.make(dir, ownsAutomation: false, prs: [RuntimeFixtures.requestedPR()])
        runtime.queue.ruleLog = .rules(in: dir.appendingPathComponent("history"))
        let server = APIServer(runtime: runtime, holder: "test", build: "dev")
        try server.start(socketURL: socketURL)
        addTeardownBlock { @MainActor in server.stop() }
        return runtime
    }

    private func connect() async throws -> APIClient {
        let client = try await ServerConnection.connect(socketURL: socketURL, client: "test").client
        addTeardownBlock { client.close() }
        return client
    }

    private var pr: PRReference { PRReference(owner: "o", repo: "r", number: 1) }

    func testTheTraceHoldsEveryConditionWithItsValues() async throws {
        let rules = try XCTUnwrap(try RuleDirectory.compile(
            ["select/10-bots.yaml": Self.skipBots, "lists.yaml": "bots: [a]\n"], root: "/r"))
        let trace = rules.traceSelect(ReviewAdmission.selectFacts(
            pr: RuntimeFixtures.requestedPR(), rules: rules, trigger: .reviewRequested, lazy: LazyFactValues(), now: Date()))
        let policy = try XCTUnwrap(trace.policies.first)
        XCTAssertEqual(policy.path, "/r/select/10-bots.yaml")
        XCTAssertEqual(policy.result, .matched("small-bot-changes: skip (a small bot change)"))
        let condition = try XCTUnwrap(policy.conditions.first)
        XCTAssertEqual(condition.holds, true)
        XCTAssertEqual(condition.line, 4)
        XCTAssertEqual(condition.terms.map(\.text), ["pr.author in lists.bots", "pr.additions < 10"])
        XCTAssertEqual(condition.terms[1].inputs, [RuleTrace.Input(text: "pr.additions", value: "1")])
        XCTAssertEqual(trace.matched, policy)
    }

    func testADraftIsTriedOnAPRWithoutBeingSaved() async throws {
        try write("select/10-bots.yaml", Self.skipBots)
        _ = try startServer()
        let client = try await connect()

        var explanation = try await client.call(.explainRules, ExplainRulesParams(pr: pr), as: RulesExplanation.self)
        XCTAssertEqual(explanation.selectOutcome, "skipped. The rule `small-bot-changes` skips it: a small bot change.", explanation.select)
        let personal = try XCTUnwrap(explanation.layers?.last)
        XCTAssertEqual(personal.layer, .personal)
        XCTAssertEqual(personal.select?.matched?.result, .matched("small-bot-changes: skip (a small bot change)"))

        let edited = Self.skipBots.replacingOccurrences(of: "< 10", with: "< 1")
        let draft = RuleDraft(files: ["select/10-bots.yaml": edited])
        explanation = try await client.call(.explainRules, ExplainRulesParams(pr: pr, draft: draft), as: RulesExplanation.self)
        XCTAssertEqual(explanation.selectOutcome, "reviewed.")
        XCTAssertEqual(explanation.layers?.last?.select?.policies.first?.result, .noMatch)
        XCTAssertEqual(read("select/10-bots.yaml"), Self.skipBots, "a draft is never written")

        let broken = RuleDraft(files: ["select/10-bots.yaml": edited.replacingOccurrences(of: "pr.author", with: "pr.autor")])
        explanation = try await client.call(.explainRules, ExplainRulesParams(pr: pr, draft: broken), as: RulesExplanation.self)
        XCTAssertTrue(explanation.draftProblem?.contains("10-bots.yaml:4") == true, explanation.draftProblem ?? "")
        XCTAssertEqual(explanation.selectOutcome, "skipped. The rule `small-bot-changes` skips it: a small bot change.",
                       "the rules in effect, when the draft doesn't compile")
    }

    /// With no rules at all the decisions are still recorded, so a first
    /// rule shows what it would have changed.
    func testAFirstRuleShowsWhatItWouldHaveChanged() async throws {
        let runtime = try startServer()
        runtime.queue.enqueueNewReviewRequests(from: [RuntimeFixtures.requestedPR()])
        let client = try await connect()

        let records = try await client.call(.ruleRecords, RuleRecordsParams(), as: [RuleRecordSummary].self)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(record.pr, "o/r#1")
        XCTAssertEqual(record.outcome, "no rule matched; the settings decide")

        let draft = RuleDraft(files: ["select/10-bots.yaml": Self.skipBots])
        let impact = try await client.call(.ruleImpact, RuleImpactParams(draft: draft, days: 60), as: RuleImpact.self)
        XCTAssertEqual(impact.examined, 1)
        XCTAssertEqual(impact.changes.map(\.draft), ["small-bot-changes: skip (a small bot change)"])
        XCTAssertEqual(impact.changes.map(\.now), ["no rule matched; the settings decide"])

        let replay = try await client.call(.replayRule, ReplayRuleParams(id: record.id, draft: draft), as: RuleReplayResult.self)
        XCTAssertEqual(replay.now, "no rule matched; the settings decide")
        XCTAssertEqual(replay.draft, "small-bot-changes: skip (a small bot change)")
        XCTAssertEqual(replay.draftTrace?.matched?.conditions.first?.holds, true)
    }

    func testSavingRefusesRulesThatWouldntLoadAndEditsMadeMeanwhile() async throws {
        let runtime = try startServer()
        let client = try await connect()
        let path = "select/10-bots.yaml"

        let broken = Self.skipBots.replacingOccurrences(of: "pr.author", with: "pr.autor")
        do {
            _ = try await client.call(.saveRuleFile, SaveRuleFileParams(path: path, text: broken), as: APIEmpty.self)
            XCTFail("saved rules that don't compile")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, RPCError.refused)
        }
        XCTAssertNil(read(path))

        _ = try await client.call(.saveRuleFile, SaveRuleFileParams(path: path, text: Self.skipBots), as: APIEmpty.self)
        XCTAssertEqual(read(path), Self.skipBots)
        XCTAssertEqual(runtime.repoConfigs.config.compiledRules?.select.count, 1, "loaded at once")

        do {
            _ = try await client.call(.saveRuleFile, SaveRuleFileParams(path: path, text: "x", base: "older"), as: APIEmpty.self)
            XCTFail("overwrote an edit made meanwhile")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, RPCError.conflict)
        }
        do {
            _ = try await client.call(.saveRuleFile, SaveRuleFileParams(path: "../prbar.yaml", text: "{}"), as: APIEmpty.self)
            XCTFail("wrote outside the rules")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, RPCError.invalidParams)
        }

        let files = try await client.call(.ruleFiles, APIEmpty(), as: RuleFilesResult.self)
        XCTAssertEqual(files.files, ["lists.yaml": "bots: [a]\n", path: Self.skipBots])
    }

    func testAgentsMayReadRulesButNotSaveThem() {
        let agent = HelloParams(client: "mcp", protocolVersion: APIVersion.current, agent: true)
        var policy = AgentPolicy()
        policy.read = .allow
        XCTAssertNil(APIServer.denial(of: .ruleImpact, by: agent, under: policy))
        XCTAssertNotNil(APIServer.denial(of: .saveRuleFile, by: agent, under: policy))
    }

    func testNewFilesStartWithRulesThatCompile() throws {
        var files: [String: String] = [:]
        for path in ["lists.yaml", "select/10-first.yaml", "decide/10-first.yaml", "configure/10-first.yaml"] {
            files[path] = RulesWorkbench.template(for: path)
        }
        let rules = try XCTUnwrap(try RuleDirectory.compile(files, root: "/r"))
        XCTAssertEqual(rules.select.count, 1)
        XCTAssertEqual(rules.decide.count, 1)
        XCTAssertEqual(rules.configure.count, 1)
        XCTAssertEqual(rules.lists, ["team": []])
    }

    func testProblemsReadWellAndMarkTheirLines() async throws {
        let workbench = RulesWorkbench(call: RulesWorkbench.Caller(
            files: { RuleFilesResult(directory: "/tmp/x/rules", files: ["decide/1.yaml": "a"]) },
            records: { _ in [] },
            explain: { _, _ in throw RPCError(code: 0, message: "unused") },
            replay: { _, _ in throw RPCError(code: 0, message: "unused") },
            impact: { _, _ in RuleImpact(examined: 0, changes: [], draftProblem: "rules don't compile:\nERROR: /tmp/x/rules/decide/1.yaml:-1:0: yaml: line 8: could not find expected ':'") },
            save: { _ in }))
        workbench.debounce = .zero
        await workbench.load()
        workbench.edit("decide/1.yaml", "b")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(workbench.problemLines("decide/1.yaml"), [8])
        XCTAssertEqual(workbench.readable(workbench.draftProblem ?? ""), "decide/1.yaml, line 8: could not find expected ':'")
        XCTAssertEqual(
            workbench.readable("ERROR: /tmp/x/rules/select/2.yaml:4:22: undeclared reference to 'onyl'"),
            "select/2.yaml, line 4: undeclared reference to 'onyl'")
    }

    // MARK: - The model

    actor Calls {
        var explained: [RuleDraft?] = []
        func explain(_ draft: RuleDraft?) -> Int {
            explained.append(draft)
            return explained.count
        }
    }

    /// A proposal that deletes a file is tried without it: the preview runs
    /// the rules accepting it would leave, and saving that file deletes it.
    func testTryingAProposalLeavesOutTheFilesItDeletes() async throws {
        try write("lists.yaml", "bots: [a]\ncore: [a]\n")
        try write("select/10-old.yaml", Self.skipBots.replacingOccurrences(of: "lists.bots", with: "lists.core"))
        _ = try startServer()
        let client = try await connect()
        let workbench = RulesWorkbench(call: RulesWorkbench.Caller(
            files: { try await client.call(.ruleFiles, APIEmpty(), as: RuleFilesResult.self) },
            records: { _ in [] },
            explain: { pr, draft in
                try await client.call(.explainRules, ExplainRulesParams(pr: pr, draft: draft), as: RulesExplanation.self)
            },
            replay: { _, _ in throw RPCError(code: 0, message: "unused") },
            impact: { _, _ in RuleImpact(examined: 0, changes: []) },
            save: { params in _ = try await client.call(.saveRuleFile, params, as: APIEmpty.self) }))
        workbench.debounce = .zero
        await workbench.load()

        let draft = RuleDraft(
            files: ["lists.yaml": "bots: [a]\n", "select/10-new.yaml": Self.skipBots],
            removed: ["select/10-old.yaml"])
        let proposal = RuleProposal(id: UUID(), at: Date(), by: "mcp", title: "t", why: "", draft: draft, base: [:])
        workbench.open(proposal)
        XCTAssertEqual(workbench.draft, draft)
        XCTAssertTrue(workbench.isEdited("select/10-old.yaml"))

        workbench.choose(.pr(RuntimeFixtures.requestedPR()))
        for _ in 0..<100 where workbench.explanation == nil { try await Task.sleep(for: .milliseconds(20)) }
        let explanation = try XCTUnwrap(workbench.explanation, workbench.error ?? "")
        XCTAssertNil(explanation.draftProblem)
        XCTAssertEqual(explanation.layers?.last?.select?.policies.map(\.path), [dir.path + "/rules/select/10-new.yaml"])
        XCTAssertEqual(explanation.selectOutcome, "skipped. The rule `small-bot-changes` skips it: a small bot change.")

        await workbench.save("select/10-old.yaml")
        XCTAssertNil(workbench.error)
        XCTAssertNil(read("select/10-old.yaml"), "saving a deleted file deletes it")
        XCTAssertFalse(workbench.paths.contains("select/10-old.yaml"))

        workbench.open(RuleProposal(
            id: UUID(), at: Date(), by: "mcp", title: "t", why: "", draft: RuleDraft(removed: ["lists.yaml"]), base: [:]))
        workbench.revert("lists.yaml")
        workbench.edit("select/10-new.yaml", "x")
        workbench.open(RuleProposal(
            id: UUID(), at: Date(), by: "mcp", title: "t", why: "", draft: RuleDraft(removed: ["select/10-new.yaml"]), base: [:]))
        XCTAssertEqual(workbench.text("select/10-new.yaml"), Self.skipBots, "a deleted file shows what is deleted")
        XCTAssertEqual(workbench.draft?.removed, ["select/10-new.yaml"])
        XCTAssertNil(workbench.draft?.files["select/10-new.yaml"])
    }

    func testTheModelSendsOnlyChangedFilesAndKeepsTheNewestAnswer() async throws {
        let calls = Calls()
        let workbench = RulesWorkbench(call: RulesWorkbench.Caller(
            files: { RuleFilesResult(directory: "/r", files: ["lists.yaml": "a: [b]\n", "select/1.yaml": "x"]) },
            records: { _ in [] },
            explain: { _, draft in
                let n = await calls.explain(draft)
                // The first answer arrives last.
                if n == 1 { try await Task.sleep(for: .milliseconds(200)) }
                return RulesExplanation(
                    pr: RuntimeFixtures.requestedPR(), select: "", decide: nil, selectOutcome: "answer \(n)")
            },
            replay: { _, _ in throw RPCError(code: 0, message: "unused") },
            impact: { _, _ in RuleImpact(examined: 0, changes: []) },
            save: { _ in }))
        workbench.debounce = .zero
        await workbench.load()
        XCTAssertEqual(workbench.paths, ["lists.yaml", "select/1.yaml"])

        workbench.edit("select/1.yaml", "x")
        XCTAssertNil(workbench.draft, "unchanged text is not a draft")
        workbench.edit("select/1.yaml", "y")
        XCTAssertEqual(workbench.draft, RuleDraft(files: ["select/1.yaml": "y"]))

        workbench.choose(.pr(RuntimeFixtures.requestedPR()))
        try await Task.sleep(for: .milliseconds(50))
        await workbench.evaluate()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(workbench.explanation?.selectOutcome, "answer 2", "an older answer doesn't replace a newer one")
    }
}
