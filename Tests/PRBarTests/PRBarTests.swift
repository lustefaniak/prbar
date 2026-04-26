import XCTest
@testable import PRBar

final class ExecutableResolverTests: XCTestCase {
    func testFindsGit() {
        XCTAssertNotNil(
            ExecutableResolver.find("git"),
            "git should be findable on any dev macOS"
        )
    }

    func testReturnsNilForNonexistentTool() {
        XCTAssertNil(
            ExecutableResolver.find("definitely-not-a-real-tool-xyz123")
        )
    }

    func testSearchPathsIncludeHomebrew() {
        XCTAssertTrue(ExecutableResolver.searchPaths.contains("/opt/homebrew/bin"))
        XCTAssertTrue(ExecutableResolver.searchPaths.contains("/usr/local/bin"))
    }
}

final class ToolProbeTests: XCTestCase {
    func testProbeGitReturnsVersion() {
        let result = ToolProbe.probe("git")
        XCTAssertTrue(result.available, "git should probe successfully")
        XCTAssertNotNil(result.path)
        XCTAssertNotNil(result.version)
    }

    func testProbeMissingToolReturnsUnavailable() {
        let result = ToolProbe.probe("definitely-not-a-real-tool-xyz123")
        XCTAssertFalse(result.available)
        XCTAssertNil(result.path)
        XCTAssertNil(result.version)
    }
}
