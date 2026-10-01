import Foundation

/// The full review, for the runs that post nothing to GitHub.
///
/// Without this the findings are computed and dropped — the terminal
/// event carries a verdict and a count, and everything the review
/// actually said is lost unless an auto gate happened to post it. Since
/// the gates all ship off, that is the default, which makes a run cost
/// money for a number.
///
/// Carries the PR identity because the interesting destination is a file
/// under the orchestrator's state root, where a bare review blob is
/// impossible to attribute.
struct ReviewOutput: Encodable {
    let task_id: String
    let head_sha: String
    let provider: String
    let posted: Bool
    let review: AggregatedReview

    /// Written as one compact line so that `--review-json -` stays
    /// framed like the surrounding NDJSON rather than splitting into
    /// unparseable fragments. Pipe through `jq` to read it.
    func write(to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(self)
        data.append(contentsOf: [0x0A])
        if path == "-" {
            FileHandle.standardOutput.write(data)
        } else {
            try data.write(to: URL(fileURLWithPath: path))
        }
    }
}
