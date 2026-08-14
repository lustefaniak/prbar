import XCTest
@testable import PRBar

/// Regression net for the "codex shows (no --version)" report.
///
/// `codex` ships as a `#!/usr/bin/env node` script. A GUI-launched app
/// inherits the LaunchServices `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`),
/// which has no `node`, so `env` exits 127 with empty stdout and the probe
/// reports no version — even though `codex --version` works fine in a
/// terminal. `claude` is a native binary, which is why only codex showed it.
///
/// The fixture reproduces the shape exactly: an interpreter and a script
/// that finds it through `env`, both outside any system directory.
final class ToolProbeTests: XCTestCase {
    private var fixtureDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixtureDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prbar-toolprobe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)

        // Stands in for `node`: re-executes its script argument under sh.
        try write("fakeint", body: """
        #!/bin/sh
        exec /bin/sh "$@"
        """)
        // Stands in for `codex`: only runnable if `fakeint` is on the
        // child's PATH, since `env` is what resolves it.
        try write("faketool", body: """
        #!/usr/bin/env fakeint
        echo "faketool-cli 9.9.9"
        """)
    }

    override func tearDownWithError() throws {
        if let dir = fixtureDir { try? FileManager.default.removeItem(at: dir) }
        try super.tearDownWithError()
    }

    private func write(_ name: String, body: String) throws {
        let url = fixtureDir.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// The bug: a shebang CLI whose interpreter lives alongside it reports
    /// no version, because the child was spawned with an unaugmented PATH.
    func testProbesShebangToolWhoseInterpreterIsOnlyInSearchPaths() {
        let result = ToolProbe.probe("faketool", searchPaths: [fixtureDir.path])

        XCTAssertTrue(result.available, "fixture tool should resolve at \(fixtureDir.path)")
        XCTAssertEqual(
            result.version,
            "faketool-cli 9.9.9",
            "probe must run the child with PATH augmented by the search paths, "
                + "or an `#!/usr/bin/env <interpreter>` CLI reports no version"
        )
    }

    /// Sanity check on the fixture itself: with the interpreter genuinely
    /// unreachable the probe finds the binary but gets no version, so the
    /// test above is asserting on PATH augmentation and not on a tool that
    /// would have worked either way.
    func testReportsNoVersionWhenInterpreterIsUnreachable() throws {
        let toolOnlyDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prbar-toolprobe-tool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: toolOnlyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: toolOnlyDir) }

        try FileManager.default.copyItem(
            at: fixtureDir.appendingPathComponent("faketool"),
            to: toolOnlyDir.appendingPathComponent("faketool")
        )

        let result = ToolProbe.probe("faketool", searchPaths: [toolOnlyDir.path])

        XCTAssertTrue(result.available)
        XCTAssertNil(result.version)
        XCTAssertEqual(result.failure?.exitCode, 127, "should surface the shell's not-found status")
        XCTAssertNotNil(result.failure?.stderrLine, "env writes the reason to stderr")
    }

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
