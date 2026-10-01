import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One automating PRBar per state directory. The menu-bar app and
/// `prbar-review watch` both poll as the same GitHub user; two of them
/// reviewing and posting at once is the duplicate-review problem on one
/// machine. Whoever takes `<state>/runtime.lock` first automates; the
/// other either refuses to start (headless) or runs without automation
/// (the app).
///
/// An advisory `flock`, so the kernel releases it when the holder exits,
/// crash included: there is no stale lock to clean up.
final class RuntimeLock: @unchecked Sendable {
    let url: URL
    private var fd: Int32 = -1

    init(stateDirectory: URL) {
        url = stateDirectory.appendingPathComponent("runtime.lock")
    }

    /// True when this process now holds the lock. Writes `pid` and a
    /// description of the holder into the file for whoever is refused.
    func acquire(holder: String) -> Bool {
        guard fd < 0 else { return true }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let opened = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard opened >= 0 else { return false }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            close(opened)
            return false
        }
        fd = opened
        _ = ftruncate(fd, 0)
        let line = "\(ProcessInfo.processInfo.processIdentifier) \(holder)\n"
        _ = line.withCString { write(fd, $0, strlen($0)) }
        return true
    }

    /// Who holds it, as written by `acquire`: "<pid> <holder>".
    func currentHolder() -> String? {
        (try? String(contentsOf: url, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func release() {
        guard fd >= 0 else { return }
        _ = flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}
