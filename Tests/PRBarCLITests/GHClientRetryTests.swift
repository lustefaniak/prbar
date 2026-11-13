import XCTest
@testable import PRBarCore

/// Reads through a stand-in `gh`: a script that fails the first `failures`
/// calls with `stderr`, then prints an empty inbox.
final class GHClientRetryTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func fakeGH(failures: Int, stderr: String) throws -> (client: GHClient, calls: () -> Int) {
        let count = dir.appendingPathComponent("calls")
        let script = dir.appendingPathComponent("gh")
        try """
        #!/bin/sh
        n=$(cat '\(count.path)' 2>/dev/null || echo 0)
        n=$((n + 1))
        echo "$n" > '\(count.path)'
        if [ "$n" -le \(failures) ]; then echo '\(stderr)' >&2; exit 1; fi
        echo '{"data":{"viewer":{"login":"me"},"search":{"edges":[]},"rateLimit":{"remaining":5000,"cost":1,"resetAt":"2030-01-01T00:00:00Z"}}}'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let client = GHClient(executablePath: script.path, readRetryDelays: [.milliseconds(1), .milliseconds(1)])
        let calls = { Int((try? String(contentsOf: count, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0") ?? 0 }
        return (client, calls)
    }

    func testTransientFailuresAreTriedAgain() async throws {
        for stderr in ["gh: HTTP 502", "unexpected end of JSON input"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("calls"))
            let gh = try fakeGH(failures: 2, stderr: stderr)
            let prs = try await gh.client.fetchInbox()
            XCTAssertEqual(prs.count, 0, stderr)
            XCTAssertEqual(gh.calls(), 3, stderr)
        }
    }

    func testGivesUpAfterTheLastTry() async throws {
        let gh = try fakeGH(failures: 5, stderr: "gh: HTTP 502")
        do {
            _ = try await gh.client.fetchInbox()
            XCTFail("expected the 502 to surface")
        } catch let GHClient.GHError.execFailed(stderr, _) {
            XCTAssertTrue(stderr.contains("HTTP 502"), stderr)
        }
        XCTAssertEqual(gh.calls(), 3)
    }

    func testConfiguredRetriesReplaceTheDefault() async throws {
        let gh = try fakeGH(failures: 5, stderr: "gh: HTTP 502")
        await gh.client.setReadRetries([0])
        _ = try? await gh.client.fetchInbox()
        XCTAssertEqual(gh.calls(), 2)

        try? FileManager.default.removeItem(at: dir.appendingPathComponent("calls"))
        await gh.client.setReadRetries([])
        _ = try? await gh.client.fetchInbox()
        XCTAssertEqual(gh.calls(), 1)
    }

    func testReadRetriesConfig() throws {
        XCTAssertEqual(try ConfigFile.decode("version: 1\n").config.readRetries, [2, 5])
        XCTAssertEqual(try ConfigFile.decode("readRetries: [1, 3, 10]\n").config.readRetries, [1, 3, 10])
        XCTAssertEqual(try ConfigFile.decode("readRetries: []\n").config.readRetries, [])
        XCTAssertThrowsError(try ConfigFile.decode("readRetries: [-1]\n"))
        XCTAssertEqual(try ConfigFile.decode("readRetries: [3600]\n").config.readRetries, [3600])
        XCTAssertThrowsError(try ConfigFile.decode("readRetries: [3601]\n"))
        XCTAssertThrowsError(try ConfigFile.decode("readRetries: [1e30]\n"))
    }

    func testOtherFailuresAreNotRetried() async throws {
        let gh = try fakeGH(failures: 1, stderr: "gh: HTTP 401: Bad credentials")
        do {
            _ = try await gh.client.fetchInbox()
            XCTFail("expected the 401 to surface")
        } catch GHClient.GHError.execFailed {}
        XCTAssertEqual(gh.calls(), 1)
    }
}
