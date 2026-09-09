import XCTest
@testable import PRBarCore

/// `--review-json` is the only way the findings escape a run that posts
/// nothing, which is the default configuration — so its shape matters as
/// much as the review itself.
final class ReviewOutputTests: XCTestCase {
    func testWritesOneLineCarryingTheFindingsAndPRIdentity() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("prbar-review-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        try Self.output().write(to: path)

        let raw = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(
            raw.split(separator: "\n", omittingEmptySubsequences: true).count, 1,
            "must stay one line so `--review-json -` keeps NDJSON framing")

        let json = try JSONSerialization.jsonObject(
            with: Data(raw.utf8)) as? [String: Any]
        // A blob in a state directory is unattributable without these.
        XCTAssertEqual(json?["task_id"] as? String, "o/r#1")
        XCTAssertEqual(json?["head_sha"] as? String, "abc1234")
        XCTAssertEqual(json?["provider"] as? String, "claude")
        XCTAssertEqual(json?["posted"] as? Bool, false)

        let review = json?["review"] as? [String: Any]
        XCTAssertEqual(review?["summaryMarkdown"] as? String, "## Findings\n\nOne thing.")
        XCTAssertEqual((review?["annotations"] as? [[String: Any]])?.count, 1)
        let annotation = (review?["annotations"] as? [[String: Any]])?.first
        XCTAssertEqual(annotation?["path"] as? String, "Sources/A.swift")
        XCTAssertEqual(annotation?["title"] as? String, "Unchecked index")
    }

    func testRejectsAnUnwritablePath() {
        XCTAssertThrowsError(try Self.output().write(to: "/nonexistent-dir/out.json"))
    }

    func testFlagParses() {
        XCTAssertEqual(
            Invocation(args: ["--review-json", "-", "o/r#1"])?.reviewJsonPath, "-")
        XCTAssertEqual(
            Invocation(args: ["--review-json", "/tmp/r.json", "o/r#1"])?.reviewJsonPath,
            "/tmp/r.json")
        XCTAssertNil(Invocation(args: ["o/r#1"])?.reviewJsonPath)
        XCTAssertNil(Invocation(args: ["--review-json"]), "missing value is a usage error")
    }

    private static func output() -> ReviewOutput {
        ReviewOutput(
            task_id: "o/r#1", head_sha: "abc1234", provider: "claude", posted: false,
            review: AggregatedReview(
                verdict: .comment,
                confidence: 0.7,
                summaryMarkdown: "## Findings\n\nOne thing.",
                annotations: [
                    DiffAnnotation(
                        path: "Sources/A.swift", lineStart: 10, lineEnd: 10,
                        severity: .warning, title: "Unchecked index",
                        body: "This can trap on an empty collection.")
                ],
                costUsd: 0.12, toolCallCount: 3, toolNamesUsed: ["Read", "Grep"],
                perSubreview: [], isSubscriptionAuth: false))
    }
}
