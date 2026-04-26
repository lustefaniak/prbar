import XCTest
@testable import PRBar

final class ReviewTraceParserTests: XCTestCase {
    func testEmptyStreamYieldsEmptyTrace() {
        XCTAssertTrue(ReviewTraceParser.parse("").isEmpty)
    }

    func testParsesAssistantTextThenToolCallThenResult() {
        let stream = """
        {"type":"system","subtype":"init","session_id":"s"}
        {"type":"assistant","message":{"content":[{"type":"text","text":"Looking at the diff."},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"kernel-billing/log.go","offset":40,"limit":40}}]}}
        {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"package billing\\n..."}]}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"Looks fine."}]}}
        {"type":"result","subtype":"success","is_error":false,"duration_ms":2350,"total_cost_usd":0.012,"structured_output":{"verdict":"approve","summary":"x","confidence":0.9,"annotations":[]}}
        """
        let trace = ReviewTraceParser.parse(stream)
        XCTAssertEqual(trace.events.count, 5)

        guard case .assistantText(let t1) = trace.events[0] else {
            return XCTFail("expected assistantText, got \(trace.events[0])")
        }
        XCTAssertEqual(t1, "Looking at the diff.")

        guard case .toolCall(let name, let summary, _) = trace.events[1] else {
            return XCTFail("expected toolCall, got \(trace.events[1])")
        }
        XCTAssertEqual(name, "Read")
        XCTAssertTrue(summary.contains("kernel-billing/log.go"))
        XCTAssertTrue(summary.contains("[40:+40]"))

        guard case .toolResult(let toolName, let preview, let ok) = trace.events[2] else {
            return XCTFail("expected toolResult, got \(trace.events[2])")
        }
        XCTAssertEqual(toolName, "Read")    // resolved via tool_use_id
        XCTAssertTrue(ok)
        XCTAssertTrue(preview.contains("package billing"))

        guard case .assistantText = trace.events[3] else {
            return XCTFail("expected assistantText")
        }

        guard case .finalResult(let cost, let dur, let verdict) = trace.events[4] else {
            return XCTFail("expected finalResult")
        }
        XCTAssertEqual(cost ?? 0, 0.012, accuracy: 1e-6)
        XCTAssertEqual(dur, 2350)
        XCTAssertEqual(verdict, "approve")
    }

    func testTruncatesLongToolResult() {
        let huge = String(repeating: "x", count: ReviewTraceParser.toolResultPreviewLimit + 200)
        let escaped = huge   // x's are JSON-safe
        let stream = """
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"Read","input":{"file_path":"a"}}]}}
        {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":"\(escaped)"}]}}
        """
        let trace = ReviewTraceParser.parse(stream)
        guard case .toolResult(_, let preview, _) = trace.events[1] else {
            return XCTFail("expected toolResult")
        }
        XCTAssertTrue(preview.hasSuffix("…"))
        XCTAssertLessThanOrEqual(
            preview.count,
            ReviewTraceParser.toolResultPreviewLimit + 1
        )
    }

    func testEmptyAssistantTextDropped() {
        let stream = """
        {"type":"assistant","message":{"content":[{"type":"text","text":"   "}]}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"real"}]}}
        """
        let trace = ReviewTraceParser.parse(stream)
        XCTAssertEqual(trace.events.count, 1)
        guard case .assistantText(let s) = trace.events[0] else {
            return XCTFail("expected assistantText")
        }
        XCTAssertEqual(s, "real")
    }

    func testMalformedLinesIgnored() {
        let stream = """
        not json
        {"type":"assistant","message":{"content":[{"type":"text","text":"survived"}]}}
        }{
        """
        let trace = ReviewTraceParser.parse(stream)
        XCTAssertEqual(trace.events.count, 1)
    }

    func testRateLimitEventCaptured() {
        let stream = """
        {"type":"rate_limit_event","rate_limit_info":{"status":"throttled"}}
        """
        let trace = ReviewTraceParser.parse(stream)
        guard case .rateLimit(let status) = trace.events[0] else {
            return XCTFail("expected rateLimit")
        }
        XCTAssertEqual(status, "throttled")
    }

    func testToolCallSummaryFallbackForUnknownShape() {
        let stream = #"""
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"WebFetch","input":{"url":"https://example.com"}}]}}
        """#
        let trace = ReviewTraceParser.parse(stream)
        guard case .toolCall(_, let summary, _) = trace.events[0] else {
            return XCTFail("expected toolCall")
        }
        XCTAssertTrue(summary.contains("https://example.com"))
    }
}
