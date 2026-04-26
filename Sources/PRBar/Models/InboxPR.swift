import Foundation

struct CheckSummary: Sendable, Hashable, Codable {
    let typename: String        // "CheckRun" | "StatusContext"
    let name: String            // workflow/check name (or context for legacy)
    let conclusion: String?     // SUCCESS | FAILURE | NEUTRAL | … (CheckRun)
    let status: String?         // QUEUED | IN_PROGRESS | COMPLETED (CheckRun) or state (StatusContext)
    /// Click-through link for the check — `detailsUrl` for CheckRuns,
    /// `targetUrl` for legacy StatusContexts. Optional: some integrations
    /// don't supply one.
    let url: String?

    /// Three coarse buckets for the UI: failed / pending / passed. Drives
    /// sorting and icon choice in `CIStatusView`. Falls through to
    /// `.unknown` when GraphQL didn't tell us anything useful.
    var bucket: Bucket {
        switch typename {
        case "CheckRun":
            switch (status ?? "").uppercased() {
            case "QUEUED", "IN_PROGRESS", "PENDING", "WAITING", "REQUESTED":
                return .pending
            default: break
            }
            switch (conclusion ?? "").uppercased() {
            case "SUCCESS", "NEUTRAL", "SKIPPED": return .passed
            case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE":
                return .failed
            default: return .unknown
            }
        case "StatusContext":
            switch (status ?? "").uppercased() {
            case "SUCCESS":             return .passed
            case "PENDING", "EXPECTED": return .pending
            case "FAILURE", "ERROR":    return .failed
            default:                    return .unknown
            }
        default:
            return .unknown
        }
    }

    enum Bucket: Sendable, Hashable {
        case failed, pending, passed, unknown
    }
}

struct InboxPR: Identifiable, Sendable, Hashable, Codable {
    var id: String { nodeId }   // GraphQL global node ID

    let nodeId: String
    let owner: String
    let repo: String
    let number: Int
    let title: String
    let body: String
    let url: URL
    let author: String
    let headRef: String
    let baseRef: String
    let headSha: String           // commit SHA at the head — for diff cache + checkout
    let isDraft: Bool
    let role: PRRole

    let mergeable: String
    let mergeStateStatus: String
    let reviewDecision: String?
    let checkRollupState: String

    let totalAdditions: Int
    let totalDeletions: Int
    let changedFiles: Int

    let hasAutoMerge: Bool
    let autoMergeEnabledBy: String?

    let allCheckSummaries: [CheckSummary]

    /// Merge methods the repo allows (driven by repo settings + branch
    /// protection's requiresLinearHistory, both applied server-side by
    /// GitHub). Use this to filter the merge menu so we don't offer
    /// e.g. "Create merge commit" on a repo that requires linear history.
    let allowedMergeMethods: Set<MergeMethod>

    /// Whether the repo allows enabling auto-merge on PRs. Phase 2+ feature.
    let autoMergeAllowed: Bool

    /// Whether the repo deletes the head branch automatically on merge.
    /// Drives the default value of --delete-branch on `gh pr merge`.
    let deleteBranchOnMerge: Bool

    var nameWithOwner: String { "\(owner)/\(repo)" }

    /// Plain string form of the PR number — avoids SwiftUI's
    /// LocalizedStringKey grouping (which renders 20609 as "20 609").
    /// Use this in any UI string interpolation.
    var numberString: String { String(number) }

    /// True when this PR is genuinely click-to-merge ready: GitHub says
    /// `mergeStateStatus == "CLEAN"` (no conflicts, required checks
    /// passed, required reviews approved), it's not a draft, the row
    /// represents one of *my* PRs (so I'm allowed to merge it), and at
    /// least one merge method is allowed by repo policy.
    var isReadyToMerge: Bool {
        mergeStateStatus == "CLEAN"
            && !isDraft
            && !allowedMergeMethods.isEmpty
            && (role == .authored || role == .both)
    }

    /// Default merge method for this PR — first allowed in the order
    /// most teams converge on. Used as the primary action of the row's
    /// split button when there's no per-repo "last used" override.
    var preferredMergeMethod: MergeMethod? {
        for m in [MergeMethod.squash, .rebase, .merge] where allowedMergeMethods.contains(m) {
            return m
        }
        return nil
    }
}

extension InboxPR {
    init(node: InboxResponse.PullRequestNode, viewerLogin: String) {
        self.nodeId = node.id

        let parts = node.repository.nameWithOwner.split(separator: "/", maxSplits: 1)
        self.owner = parts.first.map(String.init) ?? ""
        self.repo = parts.dropFirst().first.map(String.init) ?? ""

        self.number = node.number
        self.title = node.title
        self.body = node.body
        self.url = URL(string: node.url) ?? URL(string: "https://github.com")!
        self.author = node.author?.login ?? ""
        self.headRef = node.headRefName
        self.baseRef = node.baseRefName
        self.headSha = node.commits.nodes.first?.commit.oid ?? ""
        self.isDraft = node.isDraft
        self.mergeable = node.mergeable
        self.mergeStateStatus = node.mergeStateStatus
        self.reviewDecision = node.reviewDecision
        self.totalAdditions = node.additions
        self.totalDeletions = node.deletions
        self.changedFiles = node.changedFiles
        self.hasAutoMerge = node.autoMergeRequest != nil
        self.autoMergeEnabledBy = node.autoMergeRequest?.enabledBy?.login

        var methods: Set<MergeMethod> = []
        if node.repository.squashMergeAllowed { methods.insert(.squash) }
        if node.repository.mergeCommitAllowed { methods.insert(.merge) }
        if node.repository.rebaseMergeAllowed { methods.insert(.rebase) }
        self.allowedMergeMethods = methods
        self.autoMergeAllowed = node.repository.autoMergeAllowed
        self.deleteBranchOnMerge = node.repository.deleteBranchOnMerge

        let isAuthor = (node.author?.login == viewerLogin)
        let reviewerLogins = node.reviewRequests.nodes.compactMap { $0.requestedReviewer?.login }
        let isReviewRequested = reviewerLogins.contains(viewerLogin)
        switch (isAuthor, isReviewRequested) {
        case (true, true): self.role = .both
        case (true, false): self.role = .authored
        case (false, true): self.role = .reviewRequested
        case (false, false): self.role = .other
        }

        let rollup = node.commits.nodes.first?.commit.statusCheckRollup
        self.checkRollupState = rollup?.state ?? "EMPTY"
        self.allCheckSummaries = (rollup?.contexts.nodes ?? []).compactMap { ctx in
            guard let ctx else { return nil }   // skip nulls (private/inaccessible)
            return CheckSummary(
                typename: ctx.typename,
                name: ctx.name ?? ctx.context ?? "(unknown)",
                conclusion: ctx.conclusion,
                status: ctx.status ?? ctx.state,
                url: ctx.detailsUrl ?? ctx.targetUrl
            )
        }
    }
}
