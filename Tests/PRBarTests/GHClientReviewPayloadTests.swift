import XCTest
@testable import PRBar

/// The create-review body must carry `commit_id`, or GitHub anchors every
/// inline comment in the current head diff instead of the one the review
/// read.
final class GHClientReviewPayloadTests: XCTestCase {
    private func json(commitId: String?, comments: [GHClient.InlineComment] = []) throws -> [String: Any] {
        let data = try GHClient.reviewPayloadJSON(
            event: "COMMENT", body: "", comments: comments, commitId: commitId
        )
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testCommitIdIsEncoded() throws {
        XCTAssertEqual(try json(commitId: "942108f")["commit_id"] as? String, "942108f")
    }

    func testEmptyOrNilCommitIdIsOmitted() throws {
        XCTAssertNil(try json(commitId: "")["commit_id"])
        XCTAssertNil(try json(commitId: nil)["commit_id"])
    }

    func testStartLineOnlyForMultiLineSpans() throws {
        let payload = try json(commitId: "abc", comments: [
            .init(path: "a.swift", line: 10, startLine: 10, body: "single"),
            .init(path: "b.swift", line: 20, startLine: 15, body: "span"),
        ])
        let comments = try XCTUnwrap(payload["comments"] as? [[String: Any]])
        XCTAssertNil(comments[0]["start_line"])
        XCTAssertEqual(comments[1]["start_line"] as? Int, 15)
    }
}
