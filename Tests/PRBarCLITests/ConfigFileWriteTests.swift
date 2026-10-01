import XCTest
@testable import PRBarCore

final class ConfigFileWriteTests: XCTestCase {
    /// Linux's Foundation fails `replaceItemAt` with "file doesn't exist",
    /// so every save after the first one failed there.
    func testWritingOverAnExistingFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prbar-write-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("prbar.yaml")
        try ConfigFile.write("version: 1\n", to: url)
        try ConfigFile.write("version: 2\n", to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "version: 2\n")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }
}
