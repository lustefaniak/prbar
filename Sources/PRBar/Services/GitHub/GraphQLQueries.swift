import Foundation

enum GraphQLQueries {
    /// Shared field set for the PullRequest type. Used by both the inbox
    /// search query and the single-PR refresh query so the data shape stays
    /// in sync — `InboxResponse.PullRequestNode` is the single Swift mirror
    /// of these fields.
    private static let prFieldsFragment: String = """
    fragment PRFields on PullRequest {
      id number title body url isDraft additions deletions changedFiles state
      repository {
        nameWithOwner
        mergeCommitAllowed
        squashMergeAllowed
        rebaseMergeAllowed
        autoMergeAllowed
        deleteBranchOnMerge
      }
      author { login }
      headRefName baseRefName
      mergeable mergeStateStatus reviewDecision
      autoMergeRequest { enabledBy { login } mergeMethod }
      reviewRequests(first: 10) {
        nodes { requestedReviewer { ... on User { login } } }
      }
      reviews(last: 20) {
        nodes { state author { login } submittedAt body }
      }
      comments(last: 10) {
        nodes { author { login } createdAt body isMinimized minimizedReason }
      }
      commits(last: 1) {
        nodes {
          commit {
            oid
            committedDate
            statusCheckRollup {
              state
              contexts(first: 30) {
                nodes {
                  __typename
                  ... on CheckRun     { name conclusion status detailsUrl summary }
                  ... on StatusContext { context state targetUrl description }
                }
              }
            }
          }
        }
      }
    }
    """

    /// Returns up to 50 open PRs the viewer is involved in (author, reviewer,
    /// or commenter). Single round-trip; cost ≈ 25 GraphQL points.
    static let inbox: String = """
    query Inbox {
      viewer { login }
      search(query: "is:pr is:open involves:@me archived:false", type: ISSUE, first: 50) {
        edges {
          node { ... on PullRequest { ...PRFields } }
        }
      }
      rateLimit { remaining cost resetAt }
    }
    \(prFieldsFragment)
    """

    /// Review threads for one PR, for the resolve-on-retriage path.
    ///
    /// Deliberately *not* folded into `prFieldsFragment`: the inbox query
    /// already returns ~110 KB across 50 PRs, and threads are only needed
    /// for the handful of PRs actually being retriaged. Fetched on demand
    /// instead, once per retriage.
    /// `headRefOid` rides along because resolution must be checked against
    /// the commit the triage actually reviewed. Threads are read live, so
    /// a push landing mid-review would otherwise let stale findings close
    /// threads on code nobody has looked at yet.
    static let reviewThreads: String = """
    query ReviewThreads($owner: String!, $name: String!, $number: Int!, $after: String) {
      viewer { login }
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          headRefOid
          reviewThreads(first: 100, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id
              isResolved
              isOutdated
              path
              comments(first: 100) {
                nodes { author { login } body }
              }
            }
          }
        }
      }
    }
    """

    /// Refresh a single PR in place. Cheaper than re-running `inbox` (cost ≈ 1).
    static let singlePR: String = """
    query SinglePR($owner: String!, $name: String!, $number: Int!) {
      viewer { login }
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) { ...PRFields }
      }
      rateLimit { remaining cost resetAt }
    }
    \(prFieldsFragment)
    """
}
