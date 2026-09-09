import XCTest
@testable import PRBarCore

/// The prompts and the output schema reach the CLI through
/// `Bundle.module`, which resolves to a sibling directory of the
/// executable — `<package>_<target>.resources` on Linux,
/// `.bundle` on Darwin. Nothing else in the SwiftPM build exercises that
/// lookup, and when it breaks every review fails at the first provider
/// call rather than at build time.
final class PromptResourceTests: XCTestCase {
    func testOutputSchemaLoadsFromTheModuleBundle() throws {
        let data = try PromptLibrary.outputSchema()
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(object?["properties"], "schema should carry its properties")
    }

    func testEverySystemPromptLoads() throws {
        for language in Language.allCases {
            let prompt = try PromptLibrary.systemPrompt(for: language)
            XCTAssertFalse(prompt.isEmpty, "empty system prompt for \(language.rawValue)")
        }
    }
}
