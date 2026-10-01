import Foundation

/// One PR action PRBar took or tried: a manual review post, a merge, an
/// auto-approve, a share. PR coordinates are copied in so the row stays
/// readable after the PR closes and leaves the inbox.
struct ActionRecord: Sendable, Hashable, Identifiable, Codable {
    var id = UUID()
    var timestamp: Date
    var kind: ActionLogKind
    var outcome: ActionLogOutcome
    var errorMessage: String?
    var prNodeId: String
    var owner: String
    var repo: String
    var prNumber: Int
    var prTitle: String
    /// Populated where known (review post, auto-approve fire); lets the
    /// History join to a cached AI verdict.
    var headSha: String?
    /// Merge: the method. Review posts: the verdict or the posted body.
    var detail: String?
    /// Only for actions that wrap an AI run.
    var costUsd: Double?

    var nameWithOwner: String { "\(owner)/\(repo)" }

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: ActionLogKind,
        outcome: ActionLogOutcome,
        errorMessage: String? = nil,
        prNodeId: String,
        owner: String,
        repo: String,
        prNumber: Int,
        prTitle: String,
        headSha: String? = nil,
        detail: String? = nil,
        costUsd: Double? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.outcome = outcome
        self.errorMessage = errorMessage
        self.prNodeId = prNodeId
        self.owner = owner
        self.repo = repo
        self.prNumber = prNumber
        self.prTitle = prTitle
        self.headSha = headSha
        self.detail = detail
        self.costUsd = costUsd
    }

    enum CodingKeys: String, CodingKey {
        case id, timestamp, kind, outcome, errorMessage
        case prNodeId, owner, repo, prNumber, prTitle
        case headSha, detail, costUsd
    }

    // Kinds and outcomes are stored as their raw strings and decoded
    // leniently, so a kind added by a newer build reads as `.other` in an
    // older one instead of making the whole line unreadable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        kind = ActionLogKind(rawValue: try c.decode(String.self, forKey: .kind)) ?? .other
        outcome = ActionLogOutcome(rawValue: try c.decode(String.self, forKey: .outcome)) ?? .success
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        prNodeId = try c.decodeIfPresent(String.self, forKey: .prNodeId) ?? ""
        owner = try c.decode(String.self, forKey: .owner)
        repo = try c.decode(String.self, forKey: .repo)
        prNumber = try c.decode(Int.self, forKey: .prNumber)
        prTitle = try c.decodeIfPresent(String.self, forKey: .prTitle) ?? ""
        headSha = try c.decodeIfPresent(String.self, forKey: .headSha)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        costUsd = try c.decodeIfPresent(Double.self, forKey: .costUsd)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(kind.rawValue, forKey: .kind)
        try c.encode(outcome.rawValue, forKey: .outcome)
        try c.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try c.encode(prNodeId, forKey: .prNodeId)
        try c.encode(owner, forKey: .owner)
        try c.encode(repo, forKey: .repo)
        try c.encode(prNumber, forKey: .prNumber)
        try c.encode(prTitle, forKey: .prTitle)
        try c.encodeIfPresent(headSha, forKey: .headSha)
        try c.encodeIfPresent(detail, forKey: .detail)
        try c.encodeIfPresent(costUsd, forKey: .costUsd)
    }
}

enum ReviewLogStatus: String, Sendable, Hashable, Codable, CaseIterable {
    case completed
    case failed

    var displayName: String {
        switch self {
        case .completed: return "Completed"
        case .failed:    return "Failed"
        }
    }
}

/// One AI triage that reached a terminal state. The summary lives in the
/// monthly index so listing history and summing spend never touch the
/// full reviews; the `AggregatedReview` itself is a file of its own,
/// loaded when a row is opened.
struct ReviewRecord: Sendable, Hashable, Identifiable, Codable {
    var id = UUID()
    var prNodeId: String
    var owner: String
    var repo: String
    var prNumber: Int
    var prTitle: String
    var headSha: String
    var providerId: ProviderID
    var triggeredAt: Date
    /// Equals `triggeredAt` for runs that failed before starting (daily
    /// cap reached at enqueue).
    var completedAt: Date
    var status: ReviewLogStatus
    /// Worst verdict among subreviews; nil when the run failed.
    var verdict: ReviewVerdict?
    /// Nil when unknown: codex reports none, and a claude run killed
    /// before its final event never reported one.
    var costUsd: Double?
    var errorMessage: String?
    /// Whether a full review was stored next to the index.
    var hasReview: Bool = false

    var nameWithOwner: String { "\(owner)/\(repo)" }

    init(
        id: UUID = UUID(),
        prNodeId: String,
        owner: String,
        repo: String,
        prNumber: Int,
        prTitle: String,
        headSha: String,
        providerId: ProviderID,
        triggeredAt: Date,
        completedAt: Date,
        status: ReviewLogStatus,
        verdict: ReviewVerdict? = nil,
        costUsd: Double? = nil,
        errorMessage: String? = nil,
        hasReview: Bool = false
    ) {
        self.id = id
        self.prNodeId = prNodeId
        self.owner = owner
        self.repo = repo
        self.prNumber = prNumber
        self.prTitle = prTitle
        self.headSha = headSha
        self.providerId = providerId
        self.triggeredAt = triggeredAt
        self.completedAt = completedAt
        self.status = status
        self.verdict = verdict
        self.costUsd = costUsd
        self.errorMessage = errorMessage
        self.hasReview = hasReview
    }

    enum CodingKeys: String, CodingKey {
        case id, prNodeId, owner, repo, prNumber, prTitle, headSha
        case providerId, triggeredAt, completedAt, status, verdict
        case costUsd, errorMessage, hasReview
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        prNodeId = try c.decodeIfPresent(String.self, forKey: .prNodeId) ?? ""
        owner = try c.decode(String.self, forKey: .owner)
        repo = try c.decode(String.self, forKey: .repo)
        prNumber = try c.decode(Int.self, forKey: .prNumber)
        prTitle = try c.decodeIfPresent(String.self, forKey: .prTitle) ?? ""
        headSha = try c.decodeIfPresent(String.self, forKey: .headSha) ?? ""
        providerId = (try? c.decode(ProviderID.self, forKey: .providerId)) ?? .claude
        triggeredAt = try c.decode(Date.self, forKey: .triggeredAt)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt) ?? triggeredAt
        status = (try? c.decode(ReviewLogStatus.self, forKey: .status)) ?? .failed
        verdict = try? c.decodeIfPresent(ReviewVerdict.self, forKey: .verdict)
        costUsd = try c.decodeIfPresent(Double.self, forKey: .costUsd)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        hasReview = try c.decodeIfPresent(Bool.self, forKey: .hasReview) ?? false
    }
}

/// How far a one-time import of older history has got, in records.
struct HistoryImportProgress: Sendable, Hashable, Codable {
    var done: Int
    var total: Int

    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
}

/// What the history views say about an import of older history. Nil on
/// the stores when there is nothing to say.
enum HistoryImportStatus: Sendable, Hashable, Codable {
    case running(HistoryImportProgress)
    case failed(String)
}
