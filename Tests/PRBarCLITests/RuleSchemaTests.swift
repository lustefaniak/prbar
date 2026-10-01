import XCTest
@testable import PRBarCore

/// The published schemas are what `rules schema` generates from the loader's
/// own field lists.
final class RuleSchemaTests: XCTestCase {
    func testThePublishedSchemasAreCurrent() throws {
        for file in RuleSchema.File.allCases {
            let url = RuleDocsTests.repo.appendingPathComponent("docs/schema/rules/\(file.rawValue).schema.json")
            let published = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary
            let generated = try JSONSerialization.jsonObject(with: Data(RuleSchema.json(file).utf8)) as? NSDictionary
            XCTAssertEqual(
                published, generated,
                "docs/schema/rules/\(file.rawValue).schema.json is stale: prbar-review rules schema \(file.rawValue) > docs/schema/rules/\(file.rawValue).schema.json")
        }
    }

    func testTheOutputSchemaListsWhatTheLoaderAccepts() throws {
        let decide = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(RuleSchema.json(.decide).utf8)) as? [String: Any])
        let output = try XCTUnwrap((decide["definitions"] as? [String: Any])?["output"] as? [String: Any])
        let properties = try XCTUnwrap(output["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), Set(RuleOutputs.decide.map(\.name)))
        let action = try XCTUnwrap(properties["action"] as? [String: Any])
        XCTAssertEqual(action["enum"] as? [String], RuleDecision.Action.allCases.map(\.rawValue))
    }
}
