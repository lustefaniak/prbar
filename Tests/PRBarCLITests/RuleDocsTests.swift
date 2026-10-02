import XCTest
@testable import PRBarCore

/// Every policy example in the docs compiles, so the docs can't describe a
/// fact, a function or an output field the engine doesn't have.
final class RuleDocsTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// ```yaml blocks whose first line names a file under `rules/<stage>/`.
    static func examples(in file: String) throws -> [(name: String, stage: String, text: String)] {
        let text = try String(contentsOf: repo.appendingPathComponent(file), encoding: .utf8)
        var found: [(String, String, String)] = []
        for block in text.components(separatedBy: "```yaml\n").dropFirst() {
            guard let body = block.components(separatedBy: "```").first,
                  let first = body.split(separator: "\n").first,
                  let range = first.range(of: #"rules/(select|decide|configure)/[^ ]+\.yaml"#, options: .regularExpression)
            else { continue }
            let name = String(first[range])
            found.append((name, String(name.split(separator: "/")[1]), body))
        }
        return found
    }

    func testEveryExampleCompiles() throws {
        var count = 0
        for file in ["docs/rules.md", "docs/configuration.md", "README.md"] {
            for example in try Self.examples(in: file) {
                let source = Rules.Source(path: "\(file): \(example.name)", text: example.text)
                XCTAssertNoThrow(
                    try Rules.compile(
                        select: example.stage == "select" ? [source] : [],
                        decide: example.stage == "decide" ? [source] : [],
                        configure: example.stage == "configure" ? [source] : [],
                        lists: ["trusted": [], "bots": [], "originals": []]),
                    "\(file): \(example.name)")
                count += 1
            }
        }
        XCTAssertGreaterThanOrEqual(count, 6, "the examples were found")
    }
}
