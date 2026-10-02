import XCTest
@testable import PRBarCore

/// Writing rules from outside the Rules tab, through a real server: the
/// catalog, checking drafts, a repository's rules tried before they are
/// merged, and proposals an agent makes for the user to accept.
@MainActor
final class RuleAuthoringTests: XCTestCase {
    private var dir: URL!
    private var socketURL: URL!

    nonisolated static let skipBots = RulesWorkbenchTests.skipBots

    nonisolated static let repoSkip = """
        name: team
        rule:
          match:
            - condition: pr.additions < 10
              output:
                rule: team-skips-small
                action: skip
                reason: small
        """

    override func setUp() async throws {
        dir = URL(fileURLWithPath: "/tmp/prbar-ra-\(UUID().uuidString.prefix(8))")
        socketURL = dir.appendingPathComponent("server.sock")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("rules"), withIntermediateDirectories: true)
        try write("lists.yaml", "bots: [a]\n")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ path: String, _ text: String, under root: String = "rules") throws {
        let url = dir.appendingPathComponent(root).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String) -> String? {
        try? String(contentsOf: dir.appendingPathComponent("rules").appendingPathComponent(path), encoding: .utf8)
    }

    @discardableResult
    private func startServer() throws -> PRBarRuntime {
        let runtime = RuntimeFixtures.make(dir, ownsAutomation: false, prs: [RuntimeFixtures.requestedPR()])
        runtime.queue.ruleLog = .rules(in: dir.appendingPathComponent("history"))
        let server = APIServer(runtime: runtime, holder: "test", build: "dev")
        try server.start(socketURL: socketURL)
        addTeardownBlock { @MainActor in server.stop() }
        return runtime
    }

    private func connect(agent: Bool = false) async throws -> APIClient {
        let client = try await ServerConnection.connect(socketURL: socketURL, client: agent ? "mcp:test" : "test", agent: agent).client
        addTeardownBlock { client.close() }
        return client
    }

    private var pr: PRReference { PRReference(owner: "o", repo: "r", number: 1) }

    func testTheCatalogComesFromTheServer() async throws {
        try startServer()
        let client = try await connect(agent: true)
        let all = try await client.call(.ruleCatalog, RuleCatalogParams(), as: RuleCatalogResult.self)
        XCTAssertEqual(all.stages.map(\.stage), ["configure", "select", "decide"])
        XCTAssertEqual(all.lists, ["bots"])
        let decide = try XCTUnwrap(all.stages.last)
        XCTAssertTrue(decide.facts.contains { $0.path == "pr.codeowners[].owners" })
        XCTAssertTrue(decide.outputs.contains { $0.name == "action" && $0.values?["share"] != nil })
        let configure = try XCTUnwrap(all.stages.first)
        XCTAssertTrue(configure.outputs.contains { $0.name == "auto_approve.enabled" }, "nested blocks are flattened")

        let text = RulesText.catalog(try await client.call(.ruleCatalog, RuleCatalogParams(stage: "decide"), as: RuleCatalogResult.self))
        XCTAssertTrue(text.contains("Facts in decide ("), text)
        XCTAssertTrue(text.contains("pr.codeowners"), text)
        XCTAssertTrue(RulesText.catalog(all, example: "decide-codeowner").contains("pr.codeowners.all(f, pr.author in f.owners)"))

        do {
            _ = try await client.call(.ruleCatalog, RuleCatalogParams(stage: "nope"), as: RuleCatalogResult.self)
            XCTFail("an unknown stage is refused")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, RPCError.invalidParams)
        }
    }

    func testCheckingADraft() async throws {
        try write("select/10-bots.yaml", Self.skipBots)
        try startServer()
        let client = try await connect(agent: true)

        let broken = RuleDraft(files: ["decide/50-x.yaml": "name: x\nrule:\n  match:\n    - condition: pr.nope\n      output: {rule: x, action: approve}\n"])
        var result = try await client.call(.checkRules, CheckRulesParams(draft: broken), as: CheckRulesResult.self)
        XCTAssertTrue(result.problem?.contains("decide/50-x.yaml:4") == true, result.problem ?? "")
        XCTAssertEqual(result.select, ["select/10-bots.yaml"], "laid over the rules on disk")

        let repo = RuleDraft(files: ["select/10-team.yaml": Self.repoSkip, "configure/10.yaml": "name: c\nrule:\n  match: []\n"], layer: .repo, repository: "o/r")
        result = try await client.call(.checkRules, CheckRulesParams(draft: repo), as: CheckRulesResult.self)
        XCTAssertNil(result.problem)
        XCTAssertEqual(result.select, ["select/10-team.yaml"], "a repository draft is the whole directory")
        XCTAssertTrue(result.notes.contains { $0.contains("never applied") }, "\(result.notes)")
    }

    /// A repository's rules, tried on a PR before the pull request that
    /// adds them is merged, whether or not the user trusts that repository.
    func testARepositoryDraftIsTriedAsItsLayer() async throws {
        try startServer()
        let client = try await connect(agent: true)
        let draft = RuleDraft(files: ["select/10-team.yaml": Self.repoSkip], layer: .repo, repository: "o/r")
        let explanation = try await client.call(.explainRules, ExplainRulesParams(pr: pr, draft: draft), as: RulesExplanation.self)
        XCTAssertNil(explanation.draftProblem)
        XCTAssertEqual(explanation.layers?.map(\.layer), [.repo, .personal])
        XCTAssertEqual(explanation.selectOutcome, "skipped. The rule `team-skips-small` skips it: small.", explanation.select)
        XCTAssertTrue(RulesText.explanation(explanation, draft: draft).hasPrefix("With o/r's rules from the draft"))
    }

    func testARepositoryDraftsImpactOnTheRecordedDecisions() async throws {
        let runtime = try startServer()
        runtime.queue.enqueueNewReviewRequests(from: [RuntimeFixtures.requestedPR()])
        let client = try await connect(agent: true)
        let draft = RuleDraft(files: ["select/10-team.yaml": Self.repoSkip], layer: .repo, repository: "o/r")
        let impact = try await client.call(.ruleImpact, RuleImpactParams(draft: draft, days: 30), as: RuleImpact.self)
        XCTAssertEqual(impact.examined, 1)
        XCTAssertEqual(impact.changes.map(\.draft), ["team-skips-small: skip (small)"])
        XCTAssertEqual(impact.changes.map(\.now), ["no rule matched; the settings decide"])

        let other = RuleDraft(files: draft.files, layer: .repo, repository: "o/other")
        let none = try await client.call(.ruleImpact, RuleImpactParams(draft: other, days: 30), as: RuleImpact.self)
        XCTAssertEqual(none.examined, 0, "only that repository's decisions")
        XCTAssertTrue(RulesText.impact(none, draft: other, days: 30, full: false).hasPrefix("No recorded decisions"))
    }

    func testAnAgentsProposalWaitsForTheUser() async throws {
        try write("select/10-bots.yaml", Self.skipBots)
        let runtime = try startServer()
        let agent = try await connect(agent: true)
        let edited = Self.skipBots.replacingOccurrences(of: "< 10", with: "< 5")
        let params = ProposeRulesParams(
            title: "smaller bot changes", why: "asked", draft: RuleDraft(files: ["select/10-bots.yaml": edited, "lists.yaml": "bots: [a, b]\n"]))
        let result = try await agent.call(.proposeRules, params, as: ProposeRulesResult.self)
        XCTAssertFalse(result.applied)
        XCTAssertEqual(result.proposal.by, "mcp:test")
        XCTAssertEqual(read("select/10-bots.yaml"), Self.skipBots, "nothing saved yet")
        XCTAssertEqual(runtime.repoConfigs.proposals.pending.map(\.id), [result.proposal.id])
        XCTAssertTrue(RulesText.proposed(result).contains("rules accept \(RulesText.short(result.proposal.id))"))

        do {
            _ = try await agent.call(.acceptRuleProposal, RuleProposalParams(id: result.proposal.id), as: APIEmpty.self)
            XCTFail("an agent can't accept its own proposal")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, RPCError.notPermitted)
        }

        let user = try await connect()
        _ = try await user.call(.acceptRuleProposal, RuleProposalParams(id: result.proposal.id), as: APIEmpty.self)
        XCTAssertEqual(read("select/10-bots.yaml"), edited)
        XCTAssertEqual(read("lists.yaml"), "bots: [a, b]\n")
        XCTAssertTrue(runtime.repoConfigs.proposals.pending.isEmpty)
        XCTAssertEqual(runtime.repoConfigs.config.compiledRules?.lists["bots"], ["a", "b"], "reloaded")
    }

    func testAProposalOverAFileThatMovedIsRefused() async throws {
        try write("select/10-bots.yaml", Self.skipBots)
        let runtime = try startServer()
        let agent = try await connect(agent: true)
        let params = ProposeRulesParams(
            title: "t", why: "", draft: RuleDraft(files: ["select/10-bots.yaml": Self.skipBots.replacingOccurrences(of: "< 10", with: "< 5")]))
        let result = try await agent.call(.proposeRules, params, as: ProposeRulesResult.self)
        let mine = Self.skipBots.replacingOccurrences(of: "< 10", with: "< 7")
        try write("select/10-bots.yaml", mine)

        let user = try await connect()
        do {
            _ = try await user.call(.acceptRuleProposal, RuleProposalParams(id: result.proposal.id), as: APIEmpty.self)
            XCTFail("accepted over an edit made since")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, RPCError.conflict)
        }
        XCTAssertEqual(read("select/10-bots.yaml"), mine)
        _ = try await user.call(.rejectRuleProposal, RuleProposalParams(id: result.proposal.id), as: APIEmpty.self)
        XCTAssertTrue(runtime.repoConfigs.proposals.pending.isEmpty)
    }

    func testWhatAProposalMayBe() async throws {
        let runtime = try startServer()
        let agent = try await connect(agent: true)
        func refusal(_ draft: RuleDraft) async -> RPCError? {
            do {
                _ = try await agent.call(.proposeRules, ProposeRulesParams(title: "t", why: "", draft: draft), as: ProposeRulesResult.self)
                return nil
            } catch {
                return error as? RPCError
            }
        }
        let repo = await refusal(RuleDraft(files: ["select/a.yaml": Self.repoSkip], layer: .repo, repository: "o/r"))
        XCTAssertTrue(repo?.message.contains("pull request") == true, "\(String(describing: repo))")
        let broken = await refusal(RuleDraft(files: ["select/a.yaml": "name: a\nrule:\n  match:\n    - condition: pr.nope\n      output: {rule: a, action: skip}\n"]))
        XCTAssertEqual(broken?.code, RPCError.refused)
        let elsewhere = await refusal(RuleDraft(files: ["../prbar.yaml": "x"]))
        XCTAssertEqual(elsewhere?.code, RPCError.invalidParams)
        XCTAssertTrue(runtime.repoConfigs.proposals.pending.isEmpty)
    }

    func testAgentsRulesAllowSavesAndOffRefuses() async throws {
        let runtime = try startServer()
        var config = runtime.repoConfigs.config
        config.agents.rules = .allow
        runtime.repoConfigs.replace(with: config)
        let agent = try await connect(agent: true)
        let draft = RuleDraft(files: ["select/20-team.yaml": Self.repoSkip])
        let result = try await agent.call(.proposeRules, ProposeRulesParams(title: "t", why: "", draft: draft), as: ProposeRulesResult.self)
        XCTAssertTrue(result.applied)
        XCTAssertEqual(read("select/20-team.yaml"), Self.repoSkip)

        config.agents.rules = .off
        runtime.repoConfigs.replace(with: config)
        do {
            _ = try await agent.call(.proposeRules, ProposeRulesParams(title: "t", why: "", draft: draft), as: ProposeRulesResult.self)
            XCTFail("proposed with agents.rules off")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, RPCError.notPermitted)
        }
    }

    func testMCPToolsOverTheSameEndpoints() async throws {
        try write("select/10-bots.yaml", Self.skipBots)
        let runtime = try startServer()
        try write("draft/select/10-bots.yaml", Self.skipBots.replacingOccurrences(of: "< 10", with: "< 1"), under: "")
        let session = MCPSession(socketURL: socketURL)
        func call(_ name: String, _ arguments: String) async throws -> String {
            let raw = await session.handle(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#.utf8))
            let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(raw)) as? [String: Any])
            let content = try XCTUnwrap((reply["result"] as? [String: Any])?["content"] as? [[String: Any]], "\(reply)")
            return content.compactMap { $0["text"] as? String }.joined()
        }
        let draftDir = dir.appendingPathComponent("draft").path

        var text = try await call("rules_catalog", #"{"stage":"select"}"#)
        XCTAssertTrue(text.contains("Facts in select"), text)
        text = try await call("check_rules", #"{"draft_dir":"\#(draftDir)"}"#)
        XCTAssertTrue(text.hasPrefix("Your rules with the draft compile."), text)
        text = try await call("explain_rules", #"{"pr":"o/r#1","draft_dir":"\#(draftDir)"}"#)
        XCTAssertTrue(text.contains("Outcome: reviewed."), text)
        text = try await call("check_rules", "{}")
        XCTAssertTrue(text.contains("pass draft_dir"), text)
        text = try await call("propose_rules", #"{"draft_dir":"\#(draftDir)","title":"no bot skips","why":"the user asked"}"#)
        XCTAssertTrue(text.hasPrefix("Proposed "), text)
        text = try await call("rule_proposals", "{}")
        XCTAssertTrue(text.hasPrefix("1 rule proposal waiting"), text)
        XCTAssertTrue(text.contains("why: the user asked"), text)
        XCTAssertEqual(runtime.repoConfigs.proposals.pending.first?.by, "mcp")
        await session.close()
    }

    func testTheCommandLineOverTheSameEndpoints() async throws {
        try write("select/10-bots.yaml", Self.skipBots)
        let runtime = try startServer()
        try write("draft/select/10-bots.yaml", Self.skipBots.replacingOccurrences(of: "< 10", with: "< 1"), under: "")
        let draftDir = dir.appendingPathComponent("draft").path
        let socket = socketURL!
        var out: [String] = []
        var errors: [String] = []
        func run(_ args: [String]) async throws -> Int32 {
            let command = try XCTUnwrap(RulesCommand(args: ["rules"] + args), args.joined(separator: " "))
            return await command.run(
                connect: { try await ServerConnection.connect(socketURL: socket, client: "prbar-review") },
                print: { out.append($0) }, fail: { errors.append($0) })
        }

        var code = try await run(["check", "--draft", draftDir])
        XCTAssertEqual(code, 0, errors.joined())
        code = try await run(["catalog", "decide"])
        XCTAssertTrue(out.last?.contains("pr.codeowners") == true)
        code = try await run(["propose", "--draft", draftDir, "--title", "no bot skips"])
        XCTAssertEqual(code, 0, errors.joined())
        let id = try XCTUnwrap(runtime.repoConfigs.proposals.pending.first?.id)
        code = try await run(["proposals"])
        XCTAssertTrue(out.last?.contains(RulesText.short(id)) == true)
        code = try await run(["accept", RulesText.short(id)])
        XCTAssertEqual(code, 0, errors.joined())
        XCTAssertEqual(read("select/10-bots.yaml"), Self.skipBots.replacingOccurrences(of: "< 10", with: "< 1"))
        code = try await run(["accept", "ffff"])
        XCTAssertEqual(code, 1)
        XCTAssertTrue(errors.last?.contains("no rule proposal ffff") == true, errors.joined())
    }

    func testParsing() {
        XCTAssertEqual(
            RulesCommand(args: ["rules", "impact", "--repo-rules", "/x", "--repo", "o/r", "--days", "7"]),
            .impact(RuleDraftSource(repoRules: "/x", repository: "o/r"), days: 7, full: false, configPath: nil))
        XCTAssertEqual(
            RulesCommand(args: ["rules", "propose", "--draft", "/d", "--remove", "decide/a.yaml", "--title", "t"]),
            .propose(RuleDraftSource(dir: "/d", remove: ["decide/a.yaml"]), title: "t", why: "", configPath: nil))
        XCTAssertNil(RulesCommand(args: ["rules", "propose", "--repo-rules", "/x", "--title", "t"]), "repository rules aren't proposed")
        XCTAssertNil(RulesCommand(args: ["rules", "impact"]), "impact needs a draft")
        XCTAssertEqual(RulesCommand(args: ["rules", "check"]), .check(configPath: nil))
        XCTAssertEqual(
            RulesCommand(args: ["rules", "explain", "o/r#1", "--draft", "/d"]),
            .explain(PRReference(owner: "o", repo: "r", number: 1), configPath: nil, draft: RuleDraftSource(dir: "/d")))
    }

    /// A checkout's `.prbar/rules` names its repository through `origin`.
    func testARepositoryDraftKnowsItsRepositoryFromTheCheckout() async throws {
        let checkout = dir.appendingPathComponent("checkout")
        try write("checkout/.prbar/rules/select/10-team.yaml", Self.repoSkip, under: "")
        for args in [["init", "-q"], ["remote", "add", "origin", "git@github.com:acme/monorepo.git"]] {
            _ = try await LocalChanges.git(args, in: checkout)
        }
        let draft = try await RuleDraftSource(repoRules: checkout.path).load()
        XCTAssertEqual(draft.layer, .repo)
        XCTAssertEqual(draft.repository, "acme/monorepo")
        XCTAssertEqual(Array(draft.files.keys), ["select/10-team.yaml"])
    }
}
