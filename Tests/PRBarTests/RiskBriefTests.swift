import XCTest
@testable import PRBar

final class RiskBriefTests: XCTestCase {

    // MARK: - classification

    func testClassifySource() {
        XCTAssertEqual(RiskBrief.classify("kernel-billing/audit/log.go"), .source)
        XCTAssertEqual(RiskBrief.classify("Sources/PRBar/AppDelegate.swift"), .source)
        XCTAssertEqual(RiskBrief.classify("src/index.ts"), .source)
    }

    func testClassifyTest() {
        for path in [
            "kernel-billing/audit/log_test.go",
            "Tests/PRBarTests/RiskBriefTests.swift",
            "src/foo.test.ts",
            "src/foo.spec.tsx",
            "api/tests/test_auth.py",
            "app/conftest.py",
            "java/src/FooTest.java",
        ] {
            XCTAssertEqual(RiskBrief.classify(path), .test, path)
        }
    }

    func testClassifyGenerated() {
        for path in [
            "go.sum",
            "web/yarn.lock",
            "proto/gen/billing.pb.go",
            "api/schema_pb2.py",
            "vendor/github.com/x/y.go",
            "web/node_modules/lib/index.js",
            "PRBar.xcodeproj/project.pbxproj",
        ] {
            XCTAssertEqual(RiskBrief.classify(path), .generated, path)
        }
    }

    func testClassifyDocs() {
        XCTAssertEqual(RiskBrief.classify("CLAUDE.md"), .docs)
        XCTAssertEqual(RiskBrief.classify("docs/api/overview.rst"), .docs)
        XCTAssertEqual(RiskBrief.classify("LICENSE"), .docs)
    }

    /// A generated file that also looks like a test is generated: reviewing
    /// the generator's input beats reading its output either way.
    func testGeneratedWinsOverTest() {
        XCTAssertEqual(RiskBrief.classify("proto/gen/billing_test.pb.go"), .generated)
    }

    // MARK: - test pairing

    func testNormalizedStemStripsTestAffixes() {
        XCTAssertEqual(RiskBrief.normalizedStem("audit/log.go"), "log")
        XCTAssertEqual(RiskBrief.normalizedStem("audit/log_test.go"), "log")
        XCTAssertEqual(RiskBrief.normalizedStem("Sources/Foo.swift"), "foo")
        XCTAssertEqual(RiskBrief.normalizedStem("Tests/FooTests.swift"), "foo")
        XCTAssertEqual(RiskBrief.normalizedStem("src/foo.test.ts"), "foo")
        XCTAssertEqual(RiskBrief.normalizedStem("api/test_auth.py"), "auth")
    }

    func testPairedTestSuppressesMissingTestReason() {
        let brief = RiskBrief.compute(subdiff: subdiff([
            ("audit/log.go", 10, 2),
            ("audit/log_test.go", 20, 0),
        ]))
        let source = row(brief, "audit/log.go")
        XCTAssertFalse(
            source.reasons.contains { $0.contains("no matching test") },
            "a changed sibling test should pair with the source file"
        )
        XCTAssertFalse(brief.changesSourceWithoutAnyTest)
    }

    /// The pairing is directory-agnostic on purpose: plenty of layouts keep
    /// tests in a parallel tree, and requiring a same-dir match would report
    /// every one of them as untested.
    func testPairingCrossesDirectories() {
        let brief = RiskBrief.compute(subdiff: subdiff([
            ("Sources/PRBar/Foo.swift", 10, 0),
            ("Tests/PRBarTests/FooTests.swift", 30, 0),
        ]))
        XCTAssertFalse(
            row(brief, "Sources/PRBar/Foo.swift").reasons.contains { $0.contains("no matching test") }
        )
    }

    func testUnpairedSourceGetsMissingTestReason() {
        let brief = RiskBrief.compute(subdiff: subdiff([("audit/log.go", 90, 20)]))
        XCTAssertTrue(
            row(brief, "audit/log.go").reasons.contains { $0.contains("no matching test") }
        )
        XCTAssertTrue(brief.changesSourceWithoutAnyTest)
    }

    func testDocsOnlyChangeIsNotFlaggedAsUntested() {
        let brief = RiskBrief.compute(subdiff: subdiff([("CLAUDE.md", 40, 3)]))
        XCTAssertFalse(brief.changesSourceWithoutAnyTest)
        XCTAssertTrue(brief.priorityRows.isEmpty)
        XCTAssertEqual(brief.lowSignalRows.map(\.path), ["CLAUDE.md"])
    }

    // MARK: - sensitive paths

    func testSensitiveHitOnSecurityAdjacentPath() {
        XCTAssertEqual(RiskBrief.sensitiveHit("kernel-auth/session/store.go"), "auth")
        XCTAssertEqual(RiskBrief.sensitiveHit("api/jwt_signing.go"), "jwt")
        XCTAssertNil(RiskBrief.sensitiveHit("kernel-billing/invoice/render.go"))
    }

    /// Guard against re-widening the keyword list to code-review-graph's,
    /// which matches `query`/`execute`/`request`/`http`/`connect`/`validate`
    /// — i.e. most backend files, which ranks nothing.
    func testSensitiveListStaysTight() {
        for path in [
            "kernel-billing/store/query.go",
            "kernel-jobs/runner/execute.go",
            "api/http/server.go",
            "db/connect.go",
        ] {
            XCTAssertNil(RiskBrief.sensitiveHit(path), path)
        }
    }

    // MARK: - ordering

    func testSensitiveUntestedFileOutranksPlainOne() {
        let brief = RiskBrief.compute(subdiff: subdiff([
            ("kernel-billing/invoice/render.go", 4, 1),
            ("kernel-auth/session/store.go", 4, 1),
        ]))
        XCTAssertEqual(brief.priorityRows.first?.path, "kernel-auth/session/store.go")
    }

    func testGeneratedFilesSinkBelowSource() {
        let brief = RiskBrief.compute(subdiff: subdiff([
            ("go.sum", 900, 400),
            ("audit/log.go", 3, 1),
        ]))
        XCTAssertEqual(brief.rows.first?.path, "audit/log.go")
        XCTAssertEqual(brief.rows.last?.path, "go.sum")
        XCTAssertEqual(brief.priorityRows.map(\.path), ["audit/log.go"])
    }

    func testEqualScoresOrderByPathForStability() {
        // Two files that score identically must not reshuffle between runs —
        // the brief goes into the prompt, and an unstable prompt busts the
        // review cache for no reason.
        let files = [("b/two.go", 5, 5), ("a/one.go", 5, 5)]
        let first = RiskBrief.compute(subdiff: subdiff(files)).rows.map(\.path)
        let second = RiskBrief.compute(subdiff: subdiff(files.reversed())).rows.map(\.path)
        XCTAssertEqual(first, ["a/one.go", "b/two.go"])
        XCTAssertEqual(first, second)
    }

    func testEmptySubdiffProducesEmptyBrief() {
        let brief = RiskBrief.compute(subdiff: Subdiff(subpath: "", hunks: []))
        XCTAssertTrue(brief.isEmpty)
        XCTAssertFalse(brief.changesSourceWithoutAnyTest)
    }

    // MARK: - generated-marker detection

    func testGoGeneratedMarkerIsRecognized() {
        // The canonical `go generate` header.
        XCTAssertTrue(GeneratedCodeScanner.hasMarker(
            "// Code generated by protoc-gen-go. DO NOT EDIT.\n\npackage billing\n"
        ))
        // sqlc / wire style, same convention.
        XCTAssertTrue(GeneratedCodeScanner.hasMarker(
            "// Code generated by sqlc. DO NOT EDIT.\n// versions:\n//   sqlc v1.25.0\n"
        ))
        // A license header before the marker is normal.
        XCTAssertTrue(GeneratedCodeScanner.hasMarker(
            "//go:build !ignore\n\n/*\nCopyright 2026.\n*/\n\n// Code generated by deepcopy-gen. DO NOT EDIT.\n"
        ))
    }

    func testCrossLanguageGeneratedMarkers() {
        XCTAssertTrue(GeneratedCodeScanner.hasMarker("/* @generated by protobuf-ts */\n"))
        XCTAssertTrue(GeneratedCodeScanner.hasMarker("# Automatically generated by openapi-generator\n"))
        XCTAssertTrue(GeneratedCodeScanner.hasMarker("-- autogenerated by dbt, do not edit\n"))
    }

    func testHandWrittenSourceHasNoMarker() {
        XCTAssertFalse(GeneratedCodeScanner.hasMarker(
            "package billing\n\n// Invoice renders a monthly statement.\nfunc Invoice() {}\n"
        ))
        XCTAssertFalse(GeneratedCodeScanner.hasMarker(""))
    }

    func testMarkerReclassifiesOrdinaryLookingFile() async throws {
        // `wire_gen.go` is generated but the name says nothing; without the
        // marker it would rank as untested source.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(
            "// Code generated by Wire. DO NOT EDIT.\n\npackage app\n",
            to: dir.appendingPathComponent("app/wire_gen.go")
        )
        try write("package app\n\nfunc Run() {}\n", to: dir.appendingPathComponent("app/run.go"))

        let marked = await GeneratedCodeScanner.scan(
            paths: ["app/wire_gen.go", "app/run.go"], in: dir
        )
        XCTAssertEqual(marked, ["app/wire_gen.go"])

        let brief = RiskBrief.compute(
            subdiff: subdiff([("app/wire_gen.go", 800, 200), ("app/run.go", 4, 1)]),
            markedGenerated: marked
        )
        XCTAssertEqual(brief.priorityRows.map(\.path), ["app/run.go"])
        XCTAssertEqual(row(brief, "app/wire_gen.go").fileClass, .generated)
        XCTAssertEqual(
            row(brief, "app/wire_gen.go").reasons,
            ["marked auto-generated (do-not-edit header)"]
        )
        // Reclassifying it out of `.source` also stops it inflating the
        // "changes source and no tests" signal.
        XCTAssertFalse(
            row(brief, "app/wire_gen.go").reasons.contains { $0.contains("no matching test") }
        )
    }

    func testScanSkipsMissingFiles() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marked = await GeneratedCodeScanner.scan(paths: ["nope/gone.go"], in: dir)
        XCTAssertTrue(marked.isEmpty)
    }

    /// Only the file head is read, so a marker-like string deep inside a
    /// large file doesn't reclassify it.
    func testScanOnlyReadsFileHead() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let padding = String(repeating: "// filler line\n", count: 1_000)
        try write(
            "package app\n" + padding + "// Code generated by something. DO NOT EDIT.\n",
            to: dir.appendingPathComponent("app/late.go")
        )
        XCTAssertGreaterThan(padding.utf8.count, GeneratedCodeScanner.headerByteLimit)
        let marked = await GeneratedCodeScanner.scan(paths: ["app/late.go"], in: dir)
        XCTAssertTrue(marked.isEmpty)
    }

    // MARK: - churn

    func testChurnRanksHotFileFirst() {
        let churn = ChurnWindow(
            commitsByPath: ["quiet/a.go": 1, "hot/b.go": 9],
            commitsObserved: 40,
            spanDays: 30
        )
        let brief = RiskBrief.compute(
            subdiff: subdiff([("quiet/a.go", 5, 5), ("hot/b.go", 5, 5)]),
            churn: churn
        )
        XCTAssertEqual(brief.priorityRows.first?.path, "hot/b.go")
        XCTAssertTrue(
            row(brief, "hot/b.go").reasons.contains { $0.contains("9 of the last 40 commits") }
        )
        XCTAssertEqual(brief.churnSummary, "40 commits over ~30 days")
    }

    /// Below a couple of commits the count is "whatever landed today", not a
    /// hotness signal, so it stays out of the rendered reasons even when the
    /// window itself is usable.
    func testLowCommitCountIsNotCalledOut() {
        let churn = ChurnWindow(
            commitsByPath: ["a.go": 2],
            commitsObserved: 40,
            spanDays: 30
        )
        let brief = RiskBrief.compute(subdiff: subdiff([("a.go", 5, 5)]), churn: churn)
        XCTAssertFalse(row(brief, "a.go").reasons.contains { $0.contains("commits") })
    }

    /// The bare clone is `--depth=50`, so a thin window is the common case,
    /// not an edge case. Ranking on it would present "touched by 2 of the
    /// last 4 commits" as though it meant something.
    func testThinChurnWindowIsDroppedEntirely() {
        let thinByCount = ChurnWindow(commitsByPath: ["hot/b.go": 3], commitsObserved: 4, spanDays: 30)
        for churn in [thinByCount] {
            XCTAssertFalse(churn.isUsable)
            let brief = RiskBrief.compute(subdiff: subdiff([("hot/b.go", 5, 5)]), churn: churn)
            XCTAssertNil(brief.churnSummary)
            XCTAssertFalse(row(brief, "hot/b.go").reasons.contains { $0.contains("commits") })
        }
    }

    func testChurnWindowBoundaryIsUsable() {
        XCTAssertTrue(ChurnWindow(
            commitsByPath: [:], commitsObserved: ChurnWindow.minCommits, spanDays: 30
        ).isUsable)
        XCTAssertFalse(ChurnWindow(
            commitsByPath: [:], commitsObserved: ChurnWindow.minCommits - 1, spanDays: 30
        ).isUsable)
    }

    /// A busy monorepo's `--depth=50` window spans only a few days. Gating
    /// churn on span rejected exactly those repos, so a short dense window
    /// counts as usable.
    func testDenseShortWindowIsUsable() {
        XCTAssertTrue(ChurnWindow(
            commitsByPath: ["a.go": 5], commitsObserved: 57, spanDays: 3
        ).isUsable)
    }

    // MARK: - prompt rendering

    func testPromptSectionRendersRankingAndDisclaimer() {
        let brief = RiskBrief.compute(subdiff: subdiff([
            ("kernel-auth/session/store.go", 40, 5),
            ("go.sum", 20, 3),
        ]))
        let prompt = ContextAssembler.buildUserPrompt(
            pr: makeRiskBriefPR(),
            subdiff: subdiff([("kernel-auth/session/store.go", 40, 5), ("go.sum", 20, 3)]),
            diffText: "",
            existingComments: [],
            ciFailures: [],
            toolMode: .sandboxed,
            baseSha: "abc1234",
            riskBrief: brief
        )
        XCTAssertTrue(prompt.contains("## Files changed, in suggested reading order"))
        XCTAssertTrue(prompt.contains("1. `kernel-auth/session/store.go` (+40 / -5)"))
        XCTAssertTrue(prompt.contains("sensitive area (auth)"))
        XCTAssertTrue(prompt.contains("Generated, vendored, or docs"))
        // The disclaimer is the load-bearing part of the section: without it
        // a ranked list under a risk-flavoured heading reads as evidence.
        XCTAssertTrue(prompt.contains("reading order, not a finding"))
        XCTAssertTrue(prompt.contains("clears the publication bar on its own"))
        // The brief replaces the plain file list; rendering both duplicated
        // every path and its counts.
        XCTAssertFalse(prompt.contains("## Files changed in this subreview"))
    }

    func testPromptOmitsSectionWhenNoBrief() {
        let prompt = ContextAssembler.buildUserPrompt(
            pr: makeRiskBriefPR(),
            subdiff: subdiff([("a.go", 1, 1)]),
            diffText: "",
            existingComments: [],
            ciFailures: [],
            toolMode: .sandboxed,
            baseSha: "abc1234",
            riskBrief: nil
        )
        XCTAssertFalse(prompt.contains("reading order"))
        XCTAssertTrue(prompt.contains("## Files changed in this subreview"))
    }

    func testPromptOmitsSectionForEmptyBrief() {
        let prompt = ContextAssembler.buildUserPrompt(
            pr: makeRiskBriefPR(),
            subdiff: Subdiff(subpath: "", hunks: []),
            diffText: "",
            existingComments: [],
            ciFailures: [],
            toolMode: .sandboxed,
            baseSha: "abc1234",
            riskBrief: RiskBrief.compute(subdiff: Subdiff(subpath: "", hunks: []))
        )
        XCTAssertFalse(prompt.contains("reading order"))
        XCTAssertTrue(prompt.contains("## Files changed in this subreview"))
    }

    /// The large-diff branch of the explore section tells the agent how to
    /// triage. With a brief present it should point at the ranking rather
    /// than the unordered file list.
    func testLargeDiffTriageDefersToBriefWhenPresent() {
        let big = subdiff([("kernel-auth/session/store.go", 2_000, 500)])
        let withBrief = ContextAssembler.buildUserPrompt(
            pr: makeRiskBriefPR(), subdiff: big, diffText: "", existingComments: [],
            ciFailures: [], toolMode: .sandboxed, baseSha: "abc1234",
            riskBrief: RiskBrief.compute(subdiff: big)
        )
        let without = ContextAssembler.buildUserPrompt(
            pr: makeRiskBriefPR(), subdiff: big, diffText: "", existingComments: [],
            ciFailures: [], toolMode: .sandboxed, baseSha: "abc1234", riskBrief: nil
        )
        XCTAssertGreaterThan(ContextAssembler.subdiffContentBytes(big),
                             ContextAssembler.largeDiffThresholdBytes)
        XCTAssertTrue(withBrief.contains("Work down the **reading order** above"))
        XCTAssertFalse(withBrief.contains("Start from the **Files changed** list"))
        XCTAssertTrue(without.contains("Start from the **Files changed** list"))
    }

    func testPromptCapsRankedRows() {
        let many = (0..<(ContextAssembler.riskBriefMaxRows + 4)).map {
            ("pkg/file\(String(format: "%02d", $0)).go", 3, 1)
        }
        let sub = subdiff(many)
        let prompt = ContextAssembler.buildUserPrompt(
            pr: makeRiskBriefPR(), subdiff: sub, diffText: "", existingComments: [],
            ciFailures: [], toolMode: .sandboxed, baseSha: "abc1234",
            riskBrief: RiskBrief.compute(subdiff: sub)
        )
        XCTAssertTrue(prompt.contains("and 4 more, lower-ranked"))
    }

    // MARK: - helpers

    /// Build a Subdiff from `(path, addedLines, removedLines)` triples.
    private func subdiff(_ files: [(String, Int, Int)], subpath: String = "") -> Subdiff {
        let hunks = files.map { path, adds, dels -> Hunk in
            var lines: [DiffLine] = []
            for i in 0..<adds { lines.append(.added("added line \(i) in \(path)")) }
            for i in 0..<dels { lines.append(.removed("removed line \(i) in \(path)")) }
            return Hunk(
                filePath: path,
                oldStart: 1, oldCount: dels,
                newStart: 1, newCount: adds,
                lines: lines
            )
        }
        return Subdiff(subpath: subpath, hunks: hunks)
    }

    private func makeRiskBriefPR() -> InboxPR {
        InboxPR(
            nodeId: "PR_1",
            owner: "getsynq", repo: "cloud", number: 4821,
            title: "feat: audit log",
            body: "",
            url: URL(string: "https://github.com/getsynq/cloud/pull/4821")!,
            author: "alice",
            headRef: "feat/audit", baseRef: "main",
            headSha: "abc1234",
            isDraft: false,
            role: .reviewRequested,
            mergeable: "MERGEABLE", mergeStateStatus: "CLEAN",
            reviewDecision: "REVIEW_REQUIRED",
            checkRollupState: "SUCCESS",
            totalAdditions: 312, totalDeletions: 47, changedFiles: 8,
            hasAutoMerge: false, autoMergeEnabledBy: nil,
            allCheckSummaries: [],
            allowedMergeMethods: [.squash],
            autoMergeAllowed: true, deleteBranchOnMerge: true
        )
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prbar-riskbrief-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func row(_ brief: RiskBrief, _ path: String) -> RiskBrief.FileRow {
        guard let found = brief.rows.first(where: { $0.path == path }) else {
            XCTFail("no row for \(path)")
            return RiskBrief.FileRow(
                path: path, score: 0, reasons: [], addedLines: 0,
                removedLines: 0, fileClass: .source
            )
        }
        return found
    }
}
