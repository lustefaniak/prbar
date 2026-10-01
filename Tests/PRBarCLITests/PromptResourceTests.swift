import XCTest
@testable import PRBarCore

/// The prompts and the output schema are compiled in from
/// `Sources/PRBarCore/Resources` by `bin/gen-resources`. When they stop
/// loading, every review fails at the first provider call rather than at
/// build time, and when the generated file falls behind the sources, the
/// prompt you edited is not the prompt that runs.
final class PromptResourceTests: XCTestCase {
    func testOutputSchemaLoads() throws {
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

    func testEmbeddedCopiesMatchTheSources() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PRBarCLITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/PRBarCore/Resources")
        var onDisk: [String: String] = [:]
        for dir in ["prompts", "schemas"] {
            let names = try FileManager.default.contentsOfDirectory(atPath: resources.appendingPathComponent(dir).path)
            for name in names where !name.hasPrefix(".") {
                onDisk["\(dir)/\(name)"] = try String(
                    contentsOf: resources.appendingPathComponent(dir).appendingPathComponent(name), encoding: .utf8)
            }
        }
        XCTAssertEqual(Set(EmbeddedResources.files.keys), Set(onDisk.keys), "run bin/gen-resources")
        for (key, text) in onDisk {
            XCTAssertEqual(EmbeddedResources.files[key], text, "\(key) changed; run bin/gen-resources")
        }
    }
}
