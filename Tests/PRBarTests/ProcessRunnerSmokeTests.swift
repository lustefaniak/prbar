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
