import Foundation

/// Mutex-guarded line buffer for `runStreaming`. The readability handler
/// fires on AppKit-managed dispatch queues; we drain into here and let
/// the caller pull complete lines off.
private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var captured = Data()

    func append(chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        captured.append(chunk)
    }

    /// Pull any complete `\n`-terminated lines out of the buffer. The
    /// trailing partial (no `\n` yet) stays in the buffer for the next
    /// call. Returns lines without their trailing newline.
    func takeCompleteLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let lastNewline = buffer.lastIndex(of: 0x0A) else { return [] }
        // Materialize the prefix into its own Data BEFORE mutating
        // `buffer` — `prefix(through:)` returns a SubSequence sharing
        // storage, and removeSubrange would otherwise corrupt the read.
        let complete = Data(buffer.prefix(through: lastNewline))
        buffer.removeSubrange(0...lastNewline)
        let str = String(data: complete, encoding: .utf8) ?? ""
        return str.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Trailing partial line (no newline). Called after termination to
    /// not lose data that the child wrote without flushing.
    func flushTrailing() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !buffer.isEmpty else { return nil }
        let str = String(data: buffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        buffer.removeAll()
        return (str?.isEmpty == false) ? str : nil
    }

    func fullData() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }
}

struct ProcessResult: Sendable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32

    var stdoutString: String? { String(data: stdout, encoding: .utf8) }
    var stderrString: String? { String(data: stderr, encoding: .utf8) }
    var succeeded: Bool { exitCode == 0 }
}

enum ProcessRunner {
    /// Run an external process while streaming each stdout line to a
    /// callback. Returns the full captured stdout/stderr on exit too,
    /// so callers can post-hoc parse if they want.
    ///
    /// `onStdoutLine` runs on an arbitrary serial queue (the readability
    /// handler's). Callback throwing terminates the child via SIGTERM —
    /// that's how `ClaudeProvider` enforces the cost cap mid-stream.
    ///
    /// Streaming uses `Pipe()` rather than the temp-file dance that
    /// `run(...)` uses. Pipes risk the 64 KB buffer deadlock only when
    /// reads block; the readability handler drains promptly so it's
    /// safe here. (For large *non-streamed* outputs, prefer `run(...)`.)
    static func runStreaming(
        executable: String,
        args: [String],
        cwd: URL? = nil,
        environment: [String: String]? = nil,
        stdin: Data? = nil,
        onStdoutLine: @escaping @Sendable (String) -> KillDecision
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessResult, Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = args
            if let cwd { proc.currentDirectoryURL = cwd }
            if let environment { proc.environment = environment }

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError  = errPipe

            // Accumulate captured output in a Sendable mutex-guarded box.
            let captured = LineBox()
            let stderrBox = DataBox()

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                captured.append(chunk: chunk)
                let lines = captured.takeCompleteLines()
                for line in lines {
                    let decision = onStdoutLine(line)
                    if case .kill = decision {
                        proc.terminate()
                    }
                }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                stderrBox.append(chunk)
            }

            proc.terminationHandler = { p in
                // Drain anything that's still buffered (final partial line
                // without a trailing newline goes here).
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                let tail = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                if !tail.isEmpty { captured.append(chunk: tail) }
                let errTail = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                if !errTail.isEmpty { stderrBox.append(errTail) }
                if let trailing = captured.flushTrailing() {
                    _ = onStdoutLine(trailing)
                }
                cont.resume(returning: ProcessResult(
                    stdout: captured.fullData(),
                    stderr: stderrBox.data,
                    exitCode: p.terminationStatus
                ))
            }

            do {
                if let stdin {
                    let inPipe = Pipe()
                    proc.standardInput = inPipe
                    try proc.run()
                    try inPipe.fileHandleForWriting.write(contentsOf: stdin)
                    try? inPipe.fileHandleForWriting.close()
                } else {
                    proc.standardInput = FileHandle.nullDevice
                    try proc.run()
                }
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    /// Per-line callback signal — keep running, or kill the child now
    /// (e.g. budget overrun).
    enum KillDecision: Sendable, Hashable {
        case keepRunning
        case kill
    }

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
