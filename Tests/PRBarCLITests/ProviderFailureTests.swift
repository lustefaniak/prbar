import XCTest
@testable import PRBarCore

/// A failed review's message is all the user (or an agent) gets to act on.
final class ProviderFailureTests: XCTestCase {
    func testAClaudeExitWithNothingOnStderrStillSaysWhy() {
        let message = ClaudeProvider.ClaudeError.execFailed(stderr: "", exitCode: 1).errorDescription ?? ""
        XCTAssertFalse(message.hasSuffix(": "), message)
        XCTAssertFalse(message.trimmingCharacters(in: .whitespaces).hasSuffix(":"), message)
    }

    func testACodexExitWithNothingOnStderrStillSaysWhy() {
        let message = CodexProvider.CodexError.execFailed(stderr: "", exitCode: 1).errorDescription ?? ""
        XCTAssertFalse(message.trimmingCharacters(in: .whitespaces).hasSuffix(":"), message)
    }
}
