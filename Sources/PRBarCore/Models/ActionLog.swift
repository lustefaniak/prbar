import Foundation

enum ActionLogKind: String, Sendable, CaseIterable {
    case merge
    case approve
    case comment
    case requestChanges = "request_changes"
    case autoApprove = "auto_approve"
    case autoComment = "auto_comment"
    /// Findings sent to the author under `ShareFindingsPolicy`. Its own
    /// kind rather than `autoComment` because the two post an identical
    /// COMMENT review with an identical body shape — without this the
    /// History (and any query over it) can't tell a verdict-less share
    /// from an auto-deny that chose to comment instead of block.
    case autoShare = "auto_share"
    case autoRequestChanges = "auto_request_changes"
    /// Review threads PRBar opened and later closed under
    /// `ResolveThreadsConfig`. One entry per batch, not per thread.
    case autoResolveThreads = "auto_resolve_threads"
    /// The review request a share consumed, put back. Its own kind because
    /// a failure here is what silently ends a PR's life in PRBar, so it has
    /// to be visible in History rather than buried in a log line.
    case reviewReRequested = "review_re_requested"
    case autoMergeEnable = "auto_merge_enable"
    case autoMergeDisable = "auto_merge_disable"
    case other

    var displayName: String {
        switch self {
        case .merge: "Merged"
        case .approve: "Approved"
        case .comment: "Commented"
        case .requestChanges: "Requested changes"
        case .autoApprove: "Auto-approved"
        case .autoComment: "Auto-commented"
        case .autoShare: "Shared findings"
        case .autoRequestChanges: "Auto-requested changes"
        case .autoResolveThreads: "Resolved threads"
        case .reviewReRequested: "Review re-requested"
        case .autoMergeEnable: "Auto-merge enabled"
        case .autoMergeDisable: "Auto-merge disabled"
        case .other: "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .merge: "arrow.triangle.merge"
        case .approve, .autoApprove: "checkmark.seal.fill"
        case .comment, .autoComment: "text.bubble"
        case .autoShare: "arrowshape.turn.up.right"
        case .requestChanges, .autoRequestChanges: "exclamationmark.bubble"
        case .autoResolveThreads: "checkmark.bubble"
        case .reviewReRequested: "person.badge.plus"
        case .autoMergeEnable: "clock.arrow.2.circlepath"
        case .autoMergeDisable: "clock.badge.xmark"
        case .other: "circle"
        }
    }
}

enum ActionLogOutcome: String, Sendable {
    case success
    case failure
}
