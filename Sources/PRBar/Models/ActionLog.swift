import Foundation
import SwiftData

/// Recorded user/AI action against a PR. Persisted via SwiftData so the
/// History tab can render a chronological list that survives relaunches
/// and keeps showing PRs that have since left the inbox.
///
/// The PR itself isn't a foreign key — actions log a denormalized snapshot
/// of repo + number + title at the time of the action so history stays
/// readable even after the PR is merged/closed and falls off the inbox.
@Model
final class ActionLogEntry {
    /// Stable id; defaulted so callers don't have to thread one through.
    var id: UUID = UUID()

    /// When the action was initiated (we record on success *or* failure).
    var timestamp: Date = Date()

    /// Raw value of `ActionLogKind`. Stored as String so a future kind
    /// rename / new-case addition doesn't trip an old store.
    var kindRaw: String = ""

    /// Raw value of `ActionLogOutcome`. `.success` or `.failure`.
    var outcomeRaw: String = ""

    /// Localized error description when `outcomeRaw == .failure`.
    var errorMessage: String?

    /// PR coords, denormalized so history rows survive the PR leaving the
    /// inbox.
    var prNodeId: String = ""
    var owner: String = ""
    var repo: String = ""
    var prNumber: Int = 0
    var prTitle: String = ""

    /// Optional head SHA — populated where known (review post / auto-
    /// approve fire). Lets History join to a cached AI verdict.
    var headSha: String?

    /// For merge: the method ("squash" / "merge" / "rebase"). For review
    /// posts: the verdict ("approve" / "comment" / "request_changes").
    /// For auto-approve: also "approve". For refresh: nil.
    var detail: String?

    /// Optional cost in USD. Only meaningful for actions that wrap an
    /// AI run (auto-approve carrying the agg review's cost).
    var costUsd: Double?

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
        self.kindRaw = kind.rawValue
        self.outcomeRaw = outcome.rawValue
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

    var kind: ActionLogKind {
        ActionLogKind(rawValue: kindRaw) ?? .other
    }

    var outcome: ActionLogOutcome {
        ActionLogOutcome(rawValue: outcomeRaw) ?? .success
    }

    var nameWithOwner: String { "\(owner)/\(repo)" }
}

enum ActionLogKind: String, Sendable, CaseIterable {
    case merge
    case approve
    case comment
    case requestChanges = "request_changes"
    case autoApprove = "auto_approve"
    case other

    var displayName: String {
        switch self {
        case .merge: "Merged"
        case .approve: "Approved"
        case .comment: "Commented"
        case .requestChanges: "Requested changes"
        case .autoApprove: "Auto-approved"
        case .other: "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .merge: "arrow.triangle.merge"
        case .approve, .autoApprove: "checkmark.seal.fill"
        case .comment: "text.bubble"
        case .requestChanges: "exclamationmark.bubble"
        case .other: "circle"
        }
    }
}

enum ActionLogOutcome: String, Sendable {
    case success
    case failure
}
