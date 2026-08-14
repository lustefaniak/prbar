import Foundation

/// Maps a review failure message to the setting that caused it.
///
/// A failed review used to say what went wrong but not where to change
/// it: "exceeded budget" named a number nobody could find, and the
/// reporter went looking for a bug instead of a slider. Pure and
/// string-driven so it works on failures recovered from the store, where
/// the original typed error is long gone.
struct ReviewFailureHint: Sendable, Hashable {
    /// One sentence naming the knob and what raising it does.
    let explanation: String
    let destination: SettingsDestination

    /// Label for the button that jumps there.
    var actionTitle: String { "Open \(destination.title)" }

    static func hint(for message: String) -> ReviewFailureHint? {
        let lower = message.lowercased()

        // Order matters: the daily cap and the per-subreview cap both
        // mention cost, and they live in different tabs.
        if lower.contains("daily") && lower.contains("cap") {
            return ReviewFailureHint(
                explanation: "Today's total AI spend hit the daily cap. Raise it, or turn it off if you're on a subscription where the reported cost isn't billed.",
                destination: .general
            )
        }
        if lower.contains("cost cap") || lower.contains("exceeded budget") || lower.contains("spent (cap") {
            return ReviewFailureHint(
                explanation: "The review ran past the per-subreview cost cap and was stopped mid-stream. A large PR or a high-effort model needs a higher cap.",
                destination: .reviewDefaults
            )
        }
        // 143 is SIGTERM — how our own wall-clock ceiling ends a run.
        if lower.contains("timed out") || lower.contains("timeout") || lower.contains("exited 143") {
            return ReviewFailureHint(
                explanation: "The review hit its wall-clock ceiling. Sandboxed reviews explore a worktree over several turns and can legitimately run minutes on a large PR.",
                destination: .reviewDefaults
            )
        }
        if lower.contains("not found") || lower.contains("not installed") {
            return ReviewFailureHint(
                explanation: "The AI CLI this repo runs on isn't resolving. Diagnostics shows which tools PRBar can see and where it looked.",
                destination: .diagnostics
            )
        }
        return nil
    }
}
