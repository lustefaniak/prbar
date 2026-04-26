import Foundation

struct ProcessResult: Sendable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32

    var stdoutString: String? { String(data: stdout, encoding: .utf8) }
    var stderrString: String? { String(data: stderr, encoding: .utf8) }
    var succeeded: Bool { exitCode == 0 }
}

enum ProcessRunner {
    static func run(
        executable: String,
        args: [String],
        cwd: URL? = nil,
        environment: [String: String]? = nil,
        stdin: Data? = nil
    ) async throws -> ProcessResult {
        try await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = args
            if let cwd { proc.currentDirectoryURL = cwd }
            if let environment { proc.environment = environment }

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            if stdin != nil {
                proc.standardInput = Pipe()
            }

            try proc.run()

            if let stdin, let inPipe = proc.standardInput as? Pipe {
                try inPipe.fileHandleForWriting.write(contentsOf: stdin)
                try? inPipe.fileHandleForWriting.close()
            }

            proc.waitUntilExit()

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            return ProcessResult(
                stdout: outData,
                stderr: errData,
                exitCode: proc.terminationStatus
            )
        }.value
    }
}
