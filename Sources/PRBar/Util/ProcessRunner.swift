import Darwin
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

/// Mutex-guarded holder so the termination handler (fires on an arbitrary
/// thread) can cancel the timeout watchdog task without a data race.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func set(_ task: Task<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        self.task = task
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        task?.cancel()
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
        timeout: Duration? = nil,
        onStdoutLine: @escaping @Sendable (String) -> KillDecision
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessResult, Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = args
            if let cwd { proc.currentDirectoryURL = cwd }
            proc.environment = childEnvironment(environment)

            // Hard wall-clock ceiling — without this a hung child (e.g. a
            // model stuck in a tool-enforcement retry loop) never resumes
            // the continuation. SIGTERM first, SIGKILL after a 5s grace
            // period if it didn't exit (Process has no native SIGKILL).
            let timeoutTaskBox = TaskBox()
            if let timeout {
                let task = Task.detached {
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    proc.terminate()
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled, proc.isRunning else { return }
                    kill(proc.processIdentifier, SIGKILL)
                }
                timeoutTaskBox.set(task)
            }

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
                timeoutTaskBox.cancel()
                // Drain anything still buffered. If the child wrote in
                // one big chunk *after* we'd registered the readability
                // handler but before we got to fire it (or wrote without
                // flushing), this catches it. Critical: split the tail
                // into complete lines BEFORE dumping the trailing
                // partial — otherwise we'd emit "a\nb\nc" as one
                // callback because flushTrailing doesn't split.
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                let tail = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                if !tail.isEmpty { captured.append(chunk: tail) }
                let errTail = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                if !errTail.isEmpty { stderrBox.append(errTail) }
                let lines = captured.takeCompleteLines()
                for line in lines {
                    _ = onStdoutLine(line)
                }
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

    /// Build the child's environment with `ExecutableResolver.searchPaths`
    /// prepended to PATH. A `.app` launched from Finder/`open` inherits the
    /// minimal GUI PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), which omits
    /// `/opt/homebrew/bin`. We resolve CLIs like `codex` to an absolute path
    /// ourselves, but `codex` is a `#!/usr/bin/env node` script — its shebang
    /// then can't find `node` and the child exits 127. Seeding PATH with the
    /// same dirs `ExecutableResolver` searches lets node (and any tools the
    /// CLI shells out to) resolve. Caller-supplied `environment` is augmented
    /// the same way rather than replaced wholesale.
    static func childEnvironment(_ override: [String: String]?) -> [String: String] {
        var env = override ?? ProcessInfo.processInfo.environment
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        var ordered: [String] = []
        for dir in ExecutableResolver.searchPaths + existing where seen.insert(dir).inserted {
            ordered.append(dir)
        }
        env["PATH"] = ordered.joined(separator: ":")
        return env
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
            proc.environment = childEnvironment(environment)
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
