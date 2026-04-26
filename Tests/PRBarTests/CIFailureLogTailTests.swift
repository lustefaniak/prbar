import XCTest
@testable import PRBar

final class CIFailureLogTailTests: XCTestCase {
    func testParseJobIdFromCheckRunUrl() {
        let url = "https://github.com/acme/platform/actions/runs/12345/job/67890"
        XCTAssertEqual(CIFailureLogTail.parseJobId(from: url), 67890)
    }

    func testParseJobIdReturnsNilForLegacyStatusContext() {
        XCTAssertNil(CIFailureLogTail.parseJobId(from: "https://ci.example.com/builds/42"))
        XCTAssertNil(CIFailureLogTail.parseJobId(from: nil))
        XCTAssertNil(CIFailureLogTail.parseJobId(from: "not a url"))
    }

    func testTailKeepsLastNLines() {
        let raw = (1...500).map { "line \($0)" }.joined(separator: "\n")
        let tail = CIFailureLogTail.tail(raw, lines: 3)
        XCTAssertEqual(tail, "line 498\nline 499\nline 500")
    }

    func testTailStripsActionsTimestamps() {
        let raw = """
        2024-05-01T12:34:56.7890123Z hello world
        2024-05-01T12:34:57.0000000Z second line
        no-timestamp third line
        """
        let tail = CIFailureLogTail.tail(raw, lines: 10)
        XCTAssertEqual(tail, "hello world\nsecond line\nno-timestamp third line")
    }
}
