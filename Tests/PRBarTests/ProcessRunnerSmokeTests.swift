import XCTest
@testable import PRBar

/// Minimal repro tests for ProcessRunner inside the XCTest host. If the GHClient
/// integration tests hang on `gh api graphql`, we can isolate whether the issue
/// is ProcessRunner itself, the gh subprocess, or the GraphQL call.
final class ProcessRunnerSmokeTests: XCTestCase {
    func testRunsEcho() async throws {
        // /bin/echo is universally present and exits immediately.
        let result = try await ProcessRunner.run(
            executable: "/bin/echo",
            args: ["hello"]
        )
        XCTAssertTrue(result.succeeded, "echo failed: \(result.stderrString ?? "")")
        XCTAssertEqual(result.stdoutString?.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    func testRunsGhVersion() async throws {
        guard let gh = ExecutableResolver.find("gh") else {
            throw XCTSkip("gh not installed")
        }
        let result = try await ProcessRunner.run(
            executable: gh,
            args: ["--version"]
        )
        XCTAssertTrue(result.succeeded, "gh --version failed: \(result.stderrString ?? "")")
        XCTAssertTrue(
            result.stdoutString?.contains("gh version") ?? false,
            "unexpected gh --version output: \(result.stdoutString ?? "")"
        )
    }

    func testRunsGhAuthStatus() async throws {
        guard let gh = ExecutableResolver.find("gh") else {
            throw XCTSkip("gh not installed")
        }
        let result = try await ProcessRunner.run(
            executable: gh,
            args: ["auth", "status"]
        )
        if !result.succeeded {
            throw XCTSkip("gh not authenticated; skipping. stderr: \(result.stderrString ?? "")")
        }
    }

    func testStreamingDeliversLinesAndCapturesTotal() async throws {
        // /bin/sh -c 'printf "a\nb\nc\n"' — three lines, three callbacks.
        let lines = LinesBox()
        let result = try await ProcessRunner.runStreaming(
            executable: "/bin/sh",
            args: ["-c", "printf 'a\\nb\\nc\\n'"],
            onStdoutLine: { line in
                lines.append(line)
                return .keepRunning
            }
        )
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(lines.snapshot(), ["a", "b", "c"])
        XCTAssertEqual(
            result.stdoutString?.trimmingCharacters(in: .whitespacesAndNewlines),
            "a\nb\nc"
        )
    }

    func testStreamingKillsChildOnDecision() async throws {
        // A `yes` loop would stream forever; we kill after the first
        // line. The child should terminate promptly and the call return.
        let lines = LinesBox()
        let result = try await ProcessRunner.runStreaming(
            executable: "/bin/sh",
            args: ["-c", "while true; do echo tick; sleep 0.05; done"],
            onStdoutLine: { line in
                lines.append(line)
                return .kill
            }
        )
        XCTAssertGreaterThanOrEqual(lines.snapshot().count, 1)
        // SIGTERM exits non-zero; we just want to confirm the call
        // returned in finite time and didn't hang.
        XCTAssertNotEqual(result.exitCode, 0)
    }

    func testRunsTinyGhGraphQL() async throws {
        guard let gh = ExecutableResolver.find("gh") else {
            throw XCTSkip("gh not installed")
        }
        // Smallest possible GraphQL request — just the viewer login.
        let result = try await ProcessRunner.run(
            executable: gh,
            args: ["api", "graphql", "-f", "query=query { viewer { login } }"]
        )
        XCTAssertTrue(result.succeeded, "gh graphql failed: \(result.stderrString ?? "")")
        XCTAssertTrue(
            result.stdoutString?.contains("\"login\":") ?? false,
            "unexpected gh graphql output: \(result.stdoutString ?? "")"
        )
    }
}

/// Thread-safe accumulator for streaming lines; the readability handler
/// invokes our callback from a background queue.
private final class LinesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) {
        lock.lock(); lines.append(line); lock.unlock()
    }
    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }
}
