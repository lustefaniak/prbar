import XCTest
@testable import PRBar

final class CommandLineToolTests: XCTestCase {
    private var dir: URL!
    private var link: URL!
    private var binary: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("prbar-cli-link-\(UUID().uuidString)")
        link = dir.appendingPathComponent("bin/prbar-review")
        binary = dir.appendingPathComponent("PRBar.app/Contents/MacOS/prbar-review")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: binary.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testInstallAndRemove() throws {
        XCTAssertEqual(CommandLineTool.state(link: link, binary: binary), .notInstalled)
        try CommandLineTool.install(link: link, binary: binary)
        XCTAssertEqual(CommandLineTool.state(link: link, binary: binary), .installed)
        try CommandLineTool.install(link: link, binary: binary)
        try CommandLineTool.uninstall(link: link)
        XCTAssertEqual(CommandLineTool.state(link: link, binary: binary), .notInstalled)
    }

    /// A link left by another copy (a dev build, an app that moved) is
    /// PRBar's own and gets repointed.
    func testRepointsALinkToAnotherCopy() throws {
        let other = dir.appendingPathComponent("Old.app/Contents/MacOS/prbar-review")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        XCTAssertEqual(CommandLineTool.state(link: link, binary: binary), .linkedElsewhere(other.standardizedFileURL.path))

        try CommandLineTool.install(link: link, binary: binary)
        XCTAssertEqual(CommandLineTool.state(link: link, binary: binary), .installed)
    }

    func testLeavesAFileItDidNotCreate() throws {
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: link.path, contents: Data("mine".utf8))
        XCTAssertEqual(CommandLineTool.state(link: link, binary: binary), .otherFile)
        XCTAssertThrowsError(try CommandLineTool.install(link: link, binary: binary))
        try CommandLineTool.uninstall(link: link)
        XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), "mine")
    }
}
