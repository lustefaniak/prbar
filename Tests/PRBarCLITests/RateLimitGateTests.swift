import XCTest
@testable import PRBarCore

final class GitHubResponseTests: XCTestCase {
    func testSplitsHeadersFromTheBody() {
        let out = "HTTP/2.0 403 Forbidden\r\nRetry-After: 60\r\nX-Ratelimit-Remaining: 12\r\n\r\n{\"message\":\"x\"}\n"
        let r = GitHubResponse(includeOutput: Data(out.utf8))
        XCTAssertEqual(r.status, 403)
        XCTAssertEqual(r.retryAfter, 60)
        XCTAssertEqual(r.remaining, 12)
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "{\"message\":\"x\"}\n")
    }

    func testPaginatedOutputKeepsEveryPageAndTheLastHeaders() {
        let out = """
        HTTP/2.0 200 OK
        X-Ratelimit-Remaining: 9

        alice
        bob

        HTTP/2.0 200 OK
        X-Ratelimit-Remaining: 8

        carol

        """
        let r = GitHubResponse(includeOutput: Data(out.utf8))
        XCTAssertEqual(r.remaining, 8)
        let rows = String(decoding: r.body, as: UTF8.self).split(separator: "\n").map(String.init)
        XCTAssertEqual(rows, ["alice", "bob", "carol"])
    }

    func testBodyBytesSurviveVerbatim() {
        let body = "{\"title\":\"a\u{2028}b\u{85}c\"}\r\n"
        let r = GitHubResponse(includeOutput: Data(("HTTP/2.0 200 OK\r\nX-Ratelimit-Remaining: 1\r\n\r\n" + body).utf8))
        XCTAssertEqual(r.remaining, 1)
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), body)
    }

    func testOutputWithoutHeadersIsAllBody() {
        let out = Data("{\"data\":{}}\n".utf8)
        let r = GitHubResponse(includeOutput: out)
        XCTAssertNil(r.status)
        XCTAssertEqual(r.body, out)
    }
}

final class RateLimitGateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func hold(_ headers: [String: String], failed: Bool = true, message: String = "", streak: Int = 0) -> TimeInterval? {
        RateLimitGate.holdUntil(
            GitHubResponse(status: 403, headers: headers), failed: failed, message: message, streak: streak, now: now
        ).map { $0.timeIntervalSince(now) }
    }

    func testGitHubsOrderOfWaits() {
        XCTAssertEqual(hold(["retry-after": "30", "x-ratelimit-remaining": "0", "x-ratelimit-reset": "1000600"]), 30)
        XCTAssertEqual(hold(["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1000600"]), 600)
        XCTAssertEqual(hold([:], message: "You have exceeded a secondary rate limit"), 60)
    }

    func testTheLastRequestOfAWindowHoldsTheNextOnes() {
        XCTAssertEqual(hold(["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1000120"], failed: false), 120)
        XCTAssertNil(hold(["x-ratelimit-remaining": "1", "x-ratelimit-reset": "1000120"], failed: false))
    }

    func testUnexplainedLimitsBackOffUpToAnHour() {
        XCTAssertEqual(hold([:], message: "API rate limit exceeded", streak: 1), 120)
        XCTAssertEqual(hold([:], message: "API rate limit exceeded", streak: 3), 480)
        XCTAssertEqual(hold([:], message: "API rate limit exceeded", streak: 20), 3600)
    }

    func testOtherForbiddenResponsesDontHold() {
        XCTAssertNil(hold(["x-ratelimit-remaining": "4000"], message: "Resource not accessible by integration (HTTP 403)"))
    }

    func testStreakResetsOnSuccess() async {
        let gate = RateLimitGate()
        let limited = GitHubResponse(status: 403)
        let first = await gate.record(limited, failed: true, message: "rate limit", now: now)
        let second = await gate.record(limited, failed: true, message: "rate limit", now: now)
        XCTAssertEqual(first.map { $0.timeIntervalSince(now) }, 60)
        XCTAssertEqual(second.map { $0.timeIntervalSince(now) }, 120)
        await gate.record(GitHubResponse(status: 200), failed: false, message: "", now: now)
        let after = await gate.record(limited, failed: true, message: "rate limit", now: now)
        XCTAssertEqual(after.map { $0.timeIntervalSince(now) }, 60)
    }
}

/// A stand-in `gh` that answers every call with a rate-limited 403.
final class GHClientRateLimitTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testARateLimitHoldsEveryLaterCall() async throws {
        let count = dir.appendingPathComponent("calls")
        let script = dir.appendingPathComponent("gh")
        try """
        #!/bin/sh
        n=$(cat '\(count.path)' 2>/dev/null || echo 0)
        echo $((n + 1)) > '\(count.path)'
        printf 'HTTP/2.0 403 Forbidden\\r\\nRetry-After: 120\\r\\n\\r\\n{"message":"You have exceeded a secondary rate limit"}\\n'
        echo 'gh: You have exceeded a secondary rate limit (HTTP 403)' >&2
        exit 1
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let client = GHClient(executablePath: script.path, readRetryDelays: [.milliseconds(1)], gate: RateLimitGate())

        for _ in 0..<2 {
            do {
                _ = try await client.fetchInbox()
                XCTFail("expected the rate limit to surface")
            } catch let GHClient.GHError.rateLimited(until) {
                XCTAssertEqual(until.timeIntervalSinceNow, 120, accuracy: 5)
            }
        }
        do {
            try await client.mergePR(owner: "o", repo: "r", number: 1, method: .squash)
            XCTFail("expected the hold to cover writes")
        } catch GHClient.GHError.rateLimited {}
        let calls = Int((try String(contentsOf: count, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(calls, 1, "nothing reaches GitHub while the hold lasts")
    }

    func testAFailedBodyMentioningRateLimitsDoesntHold() async throws {
        let script = dir.appendingPathComponent("gh")
        try """
        #!/bin/sh
        printf 'HTTP/2.0 200 OK\\r\\nX-Ratelimit-Remaining: 4000\\r\\n\\r\\n{"data":{"title":"Handle rate limit headers"},"errors":[{}]}\\n'
        echo 'gh: Could not resolve to a node' >&2
        exit 1
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let gate = RateLimitGate()
        let client = GHClient(executablePath: script.path, readRetryDelays: [], gate: gate)

        do {
            _ = try await client.fetchInbox()
            XCTFail("expected the call to fail")
        } catch GHClient.GHError.rateLimited {
            XCTFail("a PR title is not a rate limit")
        } catch {}
        let held = await gate.heldUntil
        XCTAssertNil(held)
    }
}
