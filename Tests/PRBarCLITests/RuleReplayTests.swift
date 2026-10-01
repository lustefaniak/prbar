import XCTest
@testable import PRBarCore

/// Evaluations are recorded with their facts, once per decision, and can be
/// replayed against edited rules.
@MainActor
final class RuleReplayTests: XCTestCase {
    private var dir: URL!
    private var rulesDir: URL { dir.appendingPathComponent("rules") }
    private var environment: [String: String] {
        ["XDG_STATE_HOME": dir.appendingPathComponent("state").path, "PRBAR_RULES": rulesDir.path,
         "PRBAR_CONFIG": dir.appendingPathComponent("prbar.yaml").path]
    }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("prbar-replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rulesDir.appendingPathComponent("select"), withIntermediateDirectories: true)
        try "{}\n".write(to: dir.appendingPathComponent("prbar.yaml"), atomically: true, encoding: .utf8)
        try writeSelect(#"pr.additions < 5"#)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeSelect(_ condition: String) throws {
        try """
            name: small
            rule:
              match:
                - condition: \(condition)
                  output: '{"rule": "small", "action": "skip", "reason": "small"}'
            """.write(to: rulesDir.appendingPathComponent("select/10-small.yaml"), atomically: true, encoding: .utf8)
    }

    private var log: RuleEvaluationLog {
        .rules(in: HistoryLocation.directory(environment: environment))
    }

    private func record() throws -> ReviewQueueWorker {
        let rules = try XCTUnwrap(try RuleDirectory.load(rulesDir))
        let worker = ReviewQueueWorker(diffFetcher: { _, _, _ in "" })
        worker.providerLookup = { _ in NeverProvider() }
        worker.configResolver = { _, _ in ResolvedRepoConfig(rule: RepoConfig.default, defaults: ReviewDefaults(), rules: rules) }
        worker.ruleLog = log
        return worker
    }

    func testOneRecordPerDecisionWithTheFacts() async throws {
        let worker = try record()
        let pr = RuntimeFixtures.requestedPR()
        worker.enqueueNewReviewRequests(from: [pr])
        worker.enqueueNewReviewRequests(from: [pr])
        let records = log.readAll()
        XCTAssertEqual(records.count, 1, "a poll that decides the same writes nothing")
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.stage, .select)
        XCTAssertEqual(record.pr, "o/r#1")
        XCTAssertEqual(record.rule, "small")
        XCTAssertEqual(record.outcome, "small: skip (small)")
        XCTAssertEqual(record.select?.pr.additions, 1)
        XCTAssertEqual(record.ruleFiles.map { URL(fileURLWithPath: $0).lastPathComponent }, ["10-small.yaml"])
    }

    func testReplayAgainstEditedRules() async throws {
        let worker = try record()
        worker.enqueueNewReviewRequests(from: [RuntimeFixtures.requestedPR()])
        let record = try XCTUnwrap(log.readAll().first)

        var same = RuleReplay.replay(record, rules: try RuleDirectory.load(rulesDir))
        XCTAssertFalse(same.changed)

        try writeSelect(#"pr.additions < 1"#)
        let edited = try RuleDirectory.load(rulesDir)
        same = RuleReplay.replay(record, rules: edited)
        XCTAssertTrue(same.changed)
        XCTAssertEqual(same.outcome, "no rule matched; the settings decide")
        XCTAssertTrue(RuleReplay.explain(record, rules: edited).contains("pr.additions = 1"))

        try writeSelect(#"only(pr.files, "docs/**")"#)
        let needsFiles = RuleReplay.replay(record, rules: try RuleDirectory.load(rulesDir))
        XCTAssertEqual(needsFiles.missing, [.files], "the snapshot never had the files")
    }

    /// Lists are part of the rules: an edit to `lists.yaml` replays with
    /// the edited lists, not the ones the record was made with.
    func testReplayReadsTheListsOfTheRulesItReplays() async throws {
        let worker = try record()
        worker.enqueueNewReviewRequests(from: [RuntimeFixtures.requestedPR()])
        let record = try XCTUnwrap(log.readAll().first)

        try "bots: [a]\n".write(to: rulesDir.appendingPathComponent("lists.yaml"), atomically: true, encoding: .utf8)
        try writeSelect(#"pr.author in lists.bots"#)
        let replayed = RuleReplay.replay(record, rules: try RuleDirectory.load(rulesDir))
        XCTAssertNil(replayed.error)
        XCTAssertEqual(replayed.outcome, "small: skip (small)")
        XCTAssertFalse(replayed.changed)
    }

    func testTheCommands() async throws {
        let worker = try record()
        worker.enqueueNewReviewRequests(from: [RuntimeFixtures.requestedPR()])
        let id = String(try XCTUnwrap(log.readAll().first).id.uuidString.prefix(6))
        var out: [String] = []
        var errors: [String] = []
        func run(_ args: [String]) async throws -> Int32 {
            out = []
            return await try XCTUnwrap(RulesCommand(args: ["rules"] + args))
                .run(environment: environment, print: { out.append($0) }, fail: { errors.append($0) })
        }

        var code = try await run(["history"])
        XCTAssertEqual(code, 0)
        XCTAssertTrue(out.joined().contains("select  o/r#1  small: skip (small)"), out.joined())

        try writeSelect(#"pr.additions < 1"#)
        code = try await run(["replay"])
        XCTAssertEqual(code, 0, errors.joined())
        XCTAssertTrue(out.joined().contains("1 would change"), out.joined())

        code = try await run(["replay", id])
        XCTAssertEqual(code, 0, errors.joined())
        let text = out.joined(separator: "\n")
        XCTAssertTrue(text.contains("recorded: small: skip (small)"), text)
        XCTAssertTrue(text.contains("now:      no rule matched; the settings decide"), text)
        XCTAssertTrue(text.contains("CHANGED"), text)
        XCTAssertTrue(text.contains("pr.additions < 1"), text)
    }
}
