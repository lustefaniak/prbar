import Foundation

/// One line of the worker protocol brahmanda's runner parses off stdout:
/// NDJSON, one object per line, folded by `task_id` into a phase chain.
///
/// Only the fields the orchestrator reads are here. `phase` is omitted so
/// it defaults to the pipeline name — that default is what makes the
/// event join the task's chain rather than read as sub-event noise.
struct BrahmandaEvent: Encodable {
    enum Outcome: String, Encodable {
        case started, succeeded, failed
    }

    /// The agent session this event covers. brahmanda sums `cost_usd`
    /// across a trailing window for its rolling budgets, so a review that
    /// does not report its cost is invisible to the cap.
    struct Agent: Encodable {
        let runtime: String
        let session_id: String?
        let cost_usd: Double?
    }

    let task_id: String
    let outcome: Outcome
    let note: String?
    let agent: Agent?

    init(taskId: String, outcome: Outcome, note: String? = nil, agent: Agent? = nil) {
        self.task_id = taskId
        self.outcome = outcome
        self.note = note
        self.agent = agent
    }

    /// Writes one line to stdout and flushes. Every other channel — logs,
    /// provider chatter — goes to stderr, which brahmanda captures to the
    /// worker log without parsing.
    func emit() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
