import XCTest
@testable import PRBar

final class ClaudeProviderTests: XCTestCase {
    // MARK: - argv assembly (no subprocess)

    func testNoneModeDisallowsAllKnownTools() {
        let args = ClaudeProvider.buildArgs(
            bundle: makeBundle(toolMode: .none),
            options: makeOptions(toolMode: .none)
        )
        let argString = args.joined(separator: " ")
        XCTAssertTrue(argString.contains("--disallowedTools Bash,Edit,Write,Read,Glob,Grep,WebFetch,WebSearch,Task,Agent,NotebookEdit,TodoWrite"))
        XCTAssertFalse(argString.contains("--add-dir"))
    }

    func testMinimalModeAllowsReadFamilyAndScopesAddDir() {
        let bundle = makeBundle(toolMode: .minimal, workdir: URL(fileURLWithPath: "/private/tmp/wd"))
        let args = ClaudeProvider.buildArgs(
            bundle: bundle,
            options: makeOptions(toolMode: .minimal)
        )
        let argString = args.joined(separator: " ")
        XCTAssertTrue(argString.contains("--disallowedTools Bash,Edit,Write,Task,Agent,NotebookEdit,TodoWrite"))
        XCTAssertFalse(argString.contains("Read,"))   // Read is allowed in minimal
        XCTAssertFalse(argString.contains("Grep,"))   // Grep is allowed in minimal
        XCTAssertTrue(argString.contains("--add-dir /private/tmp/wd"))
    }

    func testMinimalModeAddsAdditionalAddDirs() {
        let bundle = makeBundle(toolMode: .minimal, workdir: URL(fileURLWithPath: "/wd"))
        var opts = makeOptions(toolMode: .minimal)
        opts.additionalAddDirs = [
            URL(fileURLWithPath: "/proto"),
            URL(fileURLWithPath: "/lib/auth"),
        ]
        let args = ClaudeProvider.buildArgs(bundle: bundle, options: opts)
        // Should appear: --add-dir /wd then --add-dir /proto then --add-dir /lib/auth
        let addDirs = zip(args, args.dropFirst()).filter { $0.0 == "--add-dir" }.map { $0.1 }
        XCTAssertEqual(addDirs, ["/wd", "/proto", "/lib/auth"])
    }

    func testCommonFlagsAlwaysPresent() {
        let args = ClaudeProvider.buildArgs(
            bundle: makeBundle(),
            options: makeOptions()
        )
        XCTAssertTrue(args.contains("-p"))
        XCTAssertTrue(args.contains("--output-format"))
        XCTAssertTrue(args.contains("stream-json"))
        XCTAssertTrue(args.contains("--verbose"))
        XCTAssertTrue(args.contains("--permission-mode"))
        XCTAssertTrue(args.contains("plan"))
        XCTAssertTrue(args.contains("--append-system-prompt"))
        XCTAssertTrue(args.contains("--json-schema"))
    }

    func testModelFlagAppendedWhenSet() {
        var opts = makeOptions()
        opts.model = "haiku"
        let args = ClaudeProvider.buildArgs(bundle: makeBundle(), options: opts)
        let pairs = zip(args, args.dropFirst()).first { $0.0 == "--model" }
        XCTAssertEqual(pairs?.1, "haiku")
    }

    func testNoneModeCwdIsTempDirectory() {
        let bundle = makeBundle(toolMode: .none, workdir: URL(fileURLWithPath: "/never/used"))
        let opts = makeOptions(toolMode: .none)
        let cwd = ClaudeProvider.resolveCwd(bundle: bundle, options: opts)
        XCTAssertNotNil(cwd)
        XCTAssertNotEqual(cwd?.path, "/never/used")
        XCTAssertTrue(cwd?.path.contains("prbar-cwd-") ?? false)
    }

    func testMinimalModeCwdIsWorkdir() {
        let bundle = makeBundle(toolMode: .minimal, workdir: URL(fileURLWithPath: "/wd"))
        let opts = makeOptions(toolMode: .minimal)
        XCTAssertEqual(ClaudeProvider.resolveCwd(bundle: bundle, options: opts)?.path, "/wd")
    }

    // MARK: - helpers

    private func makeBundle(
        toolMode: ToolMode = .none,
        workdir: URL = URL(fileURLWithPath: "/tmp/wd")
    ) -> PromptBundle {
        PromptBundle(
            systemPrompt: "system",
            userPrompt: "user",
            workdir: workdir,
            prNodeId: "PR_1",
            subpath: ""
        )
    }

    private func makeOptions(toolMode: ToolMode = .none) -> ProviderOptions {
        ProviderOptions(
            model: nil,
            toolMode: toolMode,
            additionalAddDirs: [],
            maxToolCalls: 10,
            maxCostUsd: 0.30,
            timeout: .seconds(120),
            schema: Data("{}".utf8)
        )
    }
}
