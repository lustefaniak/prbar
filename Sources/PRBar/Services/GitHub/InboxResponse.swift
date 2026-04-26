import Foundation

struct InboxResponse: Decodable, Sendable {
    let data: ResponseData

    struct ResponseData: Decodable, Sendable {
        let viewer: Viewer
        let search: SearchResult
        let rateLimit: RateLimit
    }

    static func decode(_ data: Data) throws -> InboxResponse {
        try JSONDecoder().decode(InboxResponse.self, from: data)
    }

    struct Viewer: Decodable, Sendable {
        let login: String
    }

    struct SearchResult: Decodable, Sendable {
        let edges: [SearchEdge]
    }

    struct SearchEdge: Decodable, Sendable {
        let node: PullRequestNode
    }

    struct RateLimit: Decodable, Sendable {
        let remaining: Int
        let cost: Int
        let resetAt: String
    }

    struct PullRequestNode: Decodable, Sendable {
        let id: String
        let number: Int
        let title: String
        let body: String
        let url: String
        let isDraft: Bool
        let additions: Int
        let deletions: Int
        let changedFiles: Int
        let repository: Repository
        let author: Author?
        let headRefName: String
        let baseRefName: String
        let mergeable: String
        let mergeStateStatus: String
        let reviewDecision: String?
        let autoMergeRequest: AutoMergeRequest?
        let reviewRequests: NodeList<ReviewRequest>
        let reviews: NodeList<Review>
        let comments: NodeList<Comment>
        let commits: NodeList<CommitNode>
    }

    struct Repository: Decodable, Sendable {
        let nameWithOwner: String
        let mergeCommitAllowed: Bool
        let squashMergeAllowed: Bool
        let rebaseMergeAllowed: Bool
        let autoMergeAllowed: Bool
        let deleteBranchOnMerge: Bool
    }

    struct Author: Decodable, Sendable {
        let login: String
    }

    struct AutoMergeRequest: Decodable, Sendable {
        let enabledBy: Author?
    }

    struct NodeList<T: Decodable & Sendable>: Decodable, Sendable {
        let nodes: [T]
    }

    struct ReviewRequest: Decodable, Sendable {
        let requestedReviewer: ReviewRequester?
    }

    struct ReviewRequester: Decodable, Sendable {
        let login: String?
    }

    struct Review: Decodable, Sendable {
        let state: String
        let author: Author?
        let submittedAt: String?
        let body: String
    }

    struct Comment: Decodable, Sendable {
        let author: Author?
        let createdAt: String
        let body: String
    }

    struct CommitNode: Decodable, Sendable {
        let commit: Commit
    }

    struct Commit: Decodable, Sendable {
        let oid: String
        let statusCheckRollup: StatusCheckRollup?
    }

    struct StatusCheckRollup: Decodable, Sendable {
        let state: String
        let contexts: NullableNodeList<CheckContext>
    }

    /// Like `NodeList` but tolerates null entries in the `nodes` array.
    /// GitHub returns `null` for context entries the viewer can't see (e.g.
    /// check runs from a private fork the viewer doesn't have access to).
    struct NullableNodeList<T: Decodable & Sendable>: Decodable, Sendable {
        let nodes: [T?]
    }

    struct CheckContext: Decodable, Sendable {
        let typename: String
        // CheckRun branch.
        let name: String?
        let conclusion: String?
        let status: String?
        let detailsUrl: String?
        let summary: String?
        // StatusContext branch.
        let context: String?
        let state: String?
        let targetUrl: String?
        let description: String?

        enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case name, conclusion, status, detailsUrl, summary
            case context, state, targetUrl, description
        }
        // Note: we deliberately DON'T request `isRequired` here. Querying
        // CheckRun.isRequired makes gh CLI emit ~3 stderr "A pull request
        // ID or pull request number is required" lines per PR (and exit 1)
        // even though stdout JSON is valid. Confirmed via curl: the
        // GitHub API itself accepts the field. gh CLI quirk.
        // We'll compute `isRequired` from the REST branch-protection
        // cache (planned for Phase 1+), which is the canonical source.
    }
}

/// Response shape for the single-PR refresh query (GraphQLQueries.singlePR).
struct SinglePRResponse: Decodable, Sendable {
    let data: ResponseData

    struct ResponseData: Decodable, Sendable {
        let viewer: InboxResponse.Viewer
        let repository: Repository
    }

    struct Repository: Decodable, Sendable {
        let pullRequest: InboxResponse.PullRequestNode
    }
}
