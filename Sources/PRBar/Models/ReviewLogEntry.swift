import Foundation
import SwiftData

/// Append-only history of every AI triage that reached a terminal state
/// (completed or failed). Distinct from `ReviewStateEntry`, which is a
/// per-PR cache that gets overwritten on re-triage and deleted when the
/// PR leaves the inbox. ReviewLog rows are never overwritten and never
/// deleted on PR close — they're the source of truth for:
///
/// - Daily / window-based spend caps (sum costUsd over `triggeredAt >= start`).
/// - History UI: per-PR re-triage timeline, filtered exploration.
/// - Future: "use this prior triage" picker against a specific log row.
///
/// Schema-evolution: the `AggregatedReview` graph is JSON-encoded in
/// `payload`. `payloadVersion` is reserved as an escape hatch for a
/// future breaking change to that struct — bump it when the encoding
/// shape diverges from what `decodeIfPresent` can handle.
@Model
final class ReviewLogEntry {
    @Attribute(.unique) var id: UUID = UUID()

    /// PR coords, denormalized so rows survive the PR leaving the inbox
    /// (matches `ActionLogEntry`'s pattern).
    var prNodeId: String = ""
    var owner: String = ""
    var repo: String = ""
    var prNumber: Int = 0
    var prTitle: String = ""

    /// Commit SHA the triage ran against. Lets the History UI group rows
    /// per-SHA and lets a "use this prior review" flow target a specific
    /// commit.
    var headSha: String = ""

    /// Raw value of `ProviderID`. String-stored so adding/renaming a
    /// provider doesn't trip an old store.
    var providerIdRaw: String = ""

    var triggeredAt: Date = Date()

    /// When the run reached its terminal state. Equals `triggeredAt` for
    /// synchronous-fail paths (e.g. cap-blocked at enqueue time, repo
    /// excluded). Used for "elapsed" display and to sort by completion.
    var completedAt: Date = Date()

    /// Raw value of `ReviewLogStatus`. `.completed` or `.failed`.
    var statusRaw: String = ""

    /// Worst verdict among subreviews when `.completed`. Nil on `.failed`.
    /// Stored as String so a future verdict rename doesn't break old rows.
    var verdictRaw: String?

    /// Cost in USD reported by the provider. Nil when:
    /// - codex (no cost surfaced),
    /// - claude failed before emitting the terminal `result` event,
    /// - cap-blocked at enqueue (no spend incurred).
    var costUsd: Double?

    /// JSON-encoded `AggregatedReview` for `.completed`; nil for `.failed`.
    /// The full graph is here so the History UI can show the same content
    /// the user saw when the review was live, even after the PR closes.
    var payload: Data?

    /// Bump when `AggregatedReview`'s Codable shape stops being decode-
    /// compatible with old payloads. Reader can dispatch on this and skip
    /// rows it can't render rather than crashing.
    var payloadVersion: Int = 1

    /// Human-readable failure reason for `.failed` rows. Mirrors
    /// `ReviewState.Status.failed(String)`.
    var errorMessage: String?

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
        payload: Data? = nil,
        payloadVersion: Int = 1,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.prNodeId = prNodeId
        self.owner = owner
        self.repo = repo
        self.prNumber = prNumber
        self.prTitle = prTitle
        self.headSha = headSha
        self.providerIdRaw = providerId.rawValue
        self.triggeredAt = triggeredAt
        self.completedAt = completedAt
        self.statusRaw = status.rawValue
        self.verdictRaw = verdict?.rawValue
        self.costUsd = costUsd
        self.payload = payload
        self.payloadVersion = payloadVersion
        self.errorMessage = errorMessage
    }

    var providerId: ProviderID {
        ProviderID(rawValue: providerIdRaw) ?? .claude
    }

    var status: ReviewLogStatus {
        ReviewLogStatus(rawValue: statusRaw) ?? .failed
    }

    var verdict: ReviewVerdict? {
        verdictRaw.flatMap { ReviewVerdict(rawValue: $0) }
    }

    var nameWithOwner: String { "\(owner)/\(repo)" }

    /// Decode the persisted `AggregatedReview`, or nil if missing /
    /// undecodable. Best-effort — old payloads from a future schema bump
    /// silently won't render; the row is still listed (status / cost /
    /// verdict columns remain useful).
    func decodeAggregated() -> AggregatedReview? {
        guard let payload, payloadVersion <= 1 else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AggregatedReview.self, from: payload)
    }
}

enum ReviewLogStatus: String, Sendable, CaseIterable {
    case completed
    case failed

    var displayName: String {
        switch self {
        case .completed: return "Completed"
        case .failed:    return "Failed"
        }
    }
}
