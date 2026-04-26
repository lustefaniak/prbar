import Foundation

struct CheckSummary: Sendable, Hashable, Codable {
    let typename: String        // "CheckRun" | "StatusContext"
    let name: String            // workflow/check name (or context for legacy)
    let conclusion: String?     // SUCCESS | FAILURE | NEUTRAL | … (CheckRun)
    let status: String?         // QUEUED | IN_PROGRESS | COMPLETED (CheckRun) or state (StatusContext)
    let isRequired: Bool        // mirrors GitHub's "Required" badge — drives ready-to-merge logic
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

    var nameWithOwner: String { "\(owner)/\(repo)" }
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
        self.isDraft = node.isDraft
        self.mergeable = node.mergeable
        self.mergeStateStatus = node.mergeStateStatus
        self.reviewDecision = node.reviewDecision
        self.totalAdditions = node.additions
        self.totalDeletions = node.deletions
        self.changedFiles = node.changedFiles
        self.hasAutoMerge = node.autoMergeRequest != nil
        self.autoMergeEnabledBy = node.autoMergeRequest?.enabledBy?.login

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
        self.allCheckSummaries = (rollup?.contexts.nodes ?? []).map { ctx in
            CheckSummary(
                typename: ctx.typename,
                name: ctx.name ?? ctx.context ?? "(unknown)",
                conclusion: ctx.conclusion,
                status: ctx.status ?? ctx.state,
                isRequired: ctx.isRequired ?? false
            )
        }
    }
}
