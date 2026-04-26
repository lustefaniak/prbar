import XCTest
@testable import PRBar

final class PromptLibraryTests: XCTestCase {
    func testSystemBaseLoadsAndIsNotEmpty() throws {
        let prompt = try PromptLibrary.systemBase()
        XCTAssertFalse(prompt.isEmpty)
        // Cheap content check — these phrases should be in the base prompt
        // and won't change without intent.
        XCTAssertTrue(prompt.contains("verdict"))
        XCTAssertTrue(prompt.contains("annotations"))
    }

    func testOutputSchemaIsValidJSON() throws {
        let data = try PromptLibrary.outputSchema()

        struct Schema: Decodable {
            let title: String?
            let required: [String]?
        }
        let decoded = try JSONDecoder().decode(Schema.self, from: data)
        XCTAssertEqual(decoded.title, "PRBarReviewOutput")
        XCTAssertEqual(decoded.required, ["verdict", "confidence", "summary", "annotations"])
    }

    func testLanguageDetectionByExtension() {
        XCTAssertEqual(Language.from(fileExtension: "go"), .go)
        XCTAssertEqual(Language.from(fileExtension: "GO"), .go)
        XCTAssertEqual(Language.from(fileExtension: "tsx"), .typescript)
        XCTAssertEqual(Language.from(fileExtension: "swift"), .swift)
        XCTAssertEqual(Language.from(fileExtension: "rs"), .unknown)
        XCTAssertEqual(Language.from(fileExtension: ""), .unknown)
    }

    func testLanguageOverrideAvailableForKnownLanguages() {
        XCTAssertNotNil(PromptLibrary.languageOverride(for: .go))
        XCTAssertNotNil(PromptLibrary.languageOverride(for: .typescript))
        XCTAssertNotNil(PromptLibrary.languageOverride(for: .swift))
        XCTAssertNil(PromptLibrary.languageOverride(for: .unknown))
    }

    func testSystemPromptForKnownLanguageConcatenates() throws {
        let prompt = try PromptLibrary.systemPrompt(for: .go)
        let base   = try PromptLibrary.systemBase()
        XCTAssertGreaterThan(prompt.count, base.count, "language override should add text")
        XCTAssertTrue(prompt.hasPrefix(base), "language override should append, not replace")
    }

    func testSystemPromptForUnknownLanguageEqualsBase() throws {
        let prompt = try PromptLibrary.systemPrompt(for: .unknown)
        let base   = try PromptLibrary.systemBase()
        XCTAssertEqual(prompt, base)
    }
}
