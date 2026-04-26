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
    /// Runs an external process and captures its full stdout + stderr.
    ///
    /// Implementation note: we route stdout/stderr through temp files rather
    /// than `Pipe()`. Pipes on Darwin have a 64 KB default buffer; if the
    /// child writes more than that and we wait for exit before reading, the
    /// child blocks on the next write and we deadlock. Files have no such
    /// limit. The cost is two tiny temp files per call, which we delete on
    /// the way out.
    static func run(
        executable: String,
        args: [String],
        cwd: URL? = nil,
        environment: [String: String]? = nil,
        stdin: Data? = nil
    ) async throws -> ProcessResult {
        try await Task.detached(priority: .userInitiated) {
            let tmpDir = FileManager.default.temporaryDirectory
            let outURL = tmpDir.appendingPathComponent("prbar-\(UUID().uuidString).out")
            let errURL = tmpDir.appendingPathComponent("prbar-\(UUID().uuidString).err")
            FileManager.default.createFile(atPath: outURL.path, contents: nil)
            FileManager.default.createFile(atPath: errURL.path, contents: nil)
            defer {
                try? FileManager.default.removeItem(at: outURL)
                try? FileManager.default.removeItem(at: errURL)
            }

            let outHandle = try FileHandle(forWritingTo: outURL)
            let errHandle = try FileHandle(forWritingTo: errURL)
            defer {
                try? outHandle.close()
                try? errHandle.close()
            }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = args
            if let cwd { proc.currentDirectoryURL = cwd }
            if let environment { proc.environment = environment }
            proc.standardOutput = outHandle
            proc.standardError = errHandle

            if let stdin {
                let inPipe = Pipe()
                proc.standardInput = inPipe
                try proc.run()
                try inPipe.fileHandleForWriting.write(contentsOf: stdin)
                try? inPipe.fileHandleForWriting.close()
            } else {
                // Don't inherit parent stdin — under XCTest it can stay open
                // and confuse children that opportunistically read it.
                proc.standardInput = FileHandle.nullDevice
                try proc.run()
            }

            proc.waitUntilExit()

            // Close write handles so the OS flushes and our reads see all bytes.
            try? outHandle.close()
            try? errHandle.close()

            let outData = (try? Data(contentsOf: outURL)) ?? Data()
            let errData = (try? Data(contentsOf: errURL)) ?? Data()

            return ProcessResult(
                stdout: outData,
                stderr: errData,
                exitCode: proc.terminationStatus
            )
        }.value
    }
}
