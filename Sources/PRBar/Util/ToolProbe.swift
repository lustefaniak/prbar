import Foundation

struct ToolProbeResult: Identifiable, Hashable, Sendable {
    let id = UUID()
    let tool: String
    let path: String?
    let version: String?

    /// Why `--version` produced nothing, when the binary itself resolved.
    /// Keeps a probe failure self-explaining instead of the old bare
    /// "(no --version)" — that message sent someone hunting for a PRBar
    /// bug when the child had simply exited 127.
    var failure: ProbeFailure? = nil

    var available: Bool { path != nil }

    struct ProbeFailure: Hashable, Sendable {
        let exitCode: Int32
        /// First line of the child's stderr, if it wrote any.
        let stderrLine: String?
    }
}

enum ToolProbe {
    /// `searchPaths` is injectable for tests; it selects both where the
    /// binary is looked up and which directories the child process can
    /// resolve its own dependencies from.
    static func probe(_ tool: String, searchPaths: [String] = ExecutableResolver.searchPaths) -> ToolProbeResult {
        guard let path = ExecutableResolver.find(tool, in: searchPaths) else {
            return ToolProbeResult(tool: tool, path: nil, version: nil)
        }

        let outcome = runVersion(path: path, searchPaths: searchPaths)
        return ToolProbeResult(
            tool: tool,
            path: path,
            version: outcome.version,
            failure: outcome.failure
        )
    }

    private static func runVersion(
        path: String,
        searchPaths: [String]
    ) -> (version: String?, failure: ToolProbeResult.ProbeFailure?) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--version"]
        // Without this a `#!/usr/bin/env <interpreter>` CLI (codex, and any
        // npm-installed tool) can't find its interpreter under the minimal
        // PATH a GUI-launched app inherits. Same reasoning as every other
        // child we spawn — see ProcessRunner.childEnvironment.
        proc.environment = ProcessRunner.childEnvironment(nil, prepending: searchPaths)

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            return (nil, .init(exitCode: -1, stderrLine: error.localizedDescription))
        }

        // Read before waiting: --version output is tiny, but a child that
        // fills the 64 KB pipe buffer while we block on exit would deadlock.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        if let version = firstLine(of: outData) {
            return (version, nil)
        }
        return (nil, .init(exitCode: proc.terminationStatus, stderrLine: firstLine(of: errData)))
    }

    private static func firstLine(of data: Data) -> String? {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(separator: "\n").first.map(String.init)
    }
}
