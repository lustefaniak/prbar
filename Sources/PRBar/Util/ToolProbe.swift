import Foundation

struct ToolProbeResult: Identifiable, Hashable, Sendable {
    let id = UUID()
    let tool: String
    let path: String?
    let version: String?

    var available: Bool { path != nil }
}

enum ToolProbe {
    static func probe(_ tool: String) -> ToolProbeResult {
        guard let path = ExecutableResolver.find(tool) else {
            return ToolProbeResult(tool: tool, path: nil, version: nil)
        }

        let version = runVersion(path: path)
        return ToolProbeResult(tool: tool, path: path, version: version)
    }

    private static func runVersion(path: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--version"]

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(separator: "\n").first.map(String.init)
    }
}
