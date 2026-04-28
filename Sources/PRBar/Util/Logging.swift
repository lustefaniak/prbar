import Foundation
import OSLog

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
    nonisolated(unsafe) static let triage = Logger(subsystem: subsystem, category: "triage")

    /// Provider-level events: per-subreview verdict + cost + tool count.
    /// Distinct from `triage` so you can grep just the LLM-facing layer.
    nonisolated(unsafe) static let provider = Logger(subsystem: subsystem, category: "provider")

    /// Inbox poll lifecycle: start, success (with delta sizes), error.
    nonisolated(unsafe) static let poller = Logger(subsystem: subsystem, category: "poller")

    /// Readiness coordinator: notification gating decisions, batch
    /// flushes, persistent dedup hits.
    nonisolated(unsafe) static let readiness = Logger(subsystem: subsystem, category: "readiness")
}
