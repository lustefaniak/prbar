import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// Per-subsystem `Logger` registry. One subsystem
/// (`dev.lustefaniak.prbar`), one category per concern. Tail with:
///
///     /usr/bin/log show --predicate 'subsystem == "dev.lustefaniak.prbar"' \
///         --info --last 5m
///
/// Filter by category on the predicate too, e.g.
/// `subsystem == "dev.lustefaniak.prbar" AND category == "triage"`.
///
/// Conventions used at call sites:
///   - `key=value` shape, space-separated, lowercase keys. Easier to grep
///     than free-form prose and survives Console.app's column wrap.
///   - `privacy: .public` on every interpolation. PRBar already touches
///     PR titles / repo names / SHAs in plenty of other surfaces; logs
///     stay readable at the same trust level. No tokens or diff bodies
///     get logged.
///   - `notice` for one-shot decisions worth seeing in the default log
///     level; `debug` for skip-noise (per-PR auto-enqueue rejections);
///     `error` for unexpected failures.
enum PRBarLog {
    private static let subsystem = "dev.lustefaniak.prbar"

    /// AI triage decisions: enqueue / skip / cache-hit / start / done /
    /// fail. The headline category for "why did it decide X".
    static let triage = Logger(subsystem: subsystem, category: "triage")

    /// Provider-level events: per-subreview verdict + cost + tool count.
    /// Distinct from `triage` so you can grep just the LLM-facing layer.
    static let provider = Logger(subsystem: subsystem, category: "provider")

    /// Inbox poll lifecycle: start, success (with delta sizes), error.
    static let poller = Logger(subsystem: subsystem, category: "poller")

    /// Readiness coordinator: notification gating decisions, batch
    /// flushes, persistent dedup hits.
    static let readiness = Logger(subsystem: subsystem, category: "readiness")

    /// GitHub write queue: enqueue / dedup-skip / retry / run failure for
    /// post-review / merge / auto-approve actions.
    static let actions = Logger(subsystem: subsystem, category: "actions")

    /// App lifecycle: status-item install, single-instance handoff, and
    /// the re-launch "surface a window" recovery path. The place to look
    /// when the menu-bar icon went missing and the app seemed unreachable.
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
}

#if !canImport(OSLog)
/// Linux stand-in for the two `OSLog` types the call sites name, so the
/// review pipeline logs the same lines from the headless CLI without
/// every `PRBarLog` call growing a platform branch. Only the members
/// actually used are here — `debug`/`notice`/`error` and the
/// `privacy:` interpolation, which is a no-op off Apple platforms
/// (there is no unified log to redact for).
struct OSLogPrivacy: Sendable {
    static let `public` = OSLogPrivacy()
    static let `private` = OSLogPrivacy()
}

struct PRBarLogMessage: ExpressibleByStringInterpolation, Sendable {
    let text: String

    init(stringLiteral value: String) { text = value }
    init(stringInterpolation: StringInterpolation) { text = stringInterpolation.text }

    struct StringInterpolation: StringInterpolationProtocol {
        var text = ""
        init(literalCapacity: Int, interpolationCount: Int) {
            text.reserveCapacity(literalCapacity)
        }
        mutating func appendLiteral(_ literal: String) { text += literal }
        mutating func appendInterpolation(
            _ value: some Any, privacy _: OSLogPrivacy = .public
        ) {
            text += "\(value)"
        }
    }
}

/// stderr, not stdout: the CLI's stdout is brahmanda's NDJSON event
/// stream, and a stray log line there would be parsed as an event.
struct Logger: Sendable {
    let subsystem: String
    let category: String

    init(subsystem: String, category: String) {
        self.subsystem = subsystem
        self.category = category
    }

    func debug(_ message: PRBarLogMessage) { emit("debug", message) }
    func notice(_ message: PRBarLogMessage) { emit("notice", message) }
    func error(_ message: PRBarLogMessage) { emit("error", message) }

    private func emit(_ level: String, _ message: PRBarLogMessage) {
        FileHandle.standardError.write(
            Data("[\(level)] \(category): \(message.text)\n".utf8)
        )
    }
}
#endif
