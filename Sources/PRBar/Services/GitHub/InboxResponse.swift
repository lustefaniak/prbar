import Foundation

struct InboxResponse: Decodable, Sendable {
    let data: ResponseData

    struct ResponseData: Decodable, Sendable {
        let viewer: Viewer
        let search: SearchResult
        let rateLimit: RateLimit
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
        let contexts: NodeList<CheckContext>
    }

    struct CheckContext: Decodable, Sendable {
        let typename: String
        // Common across both branches (resolved per-branch below).
        let isRequired: Bool?
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
            case isRequired
            case name, conclusion, status, detailsUrl, summary
            case context, state, targetUrl, description
        }
    }
}
