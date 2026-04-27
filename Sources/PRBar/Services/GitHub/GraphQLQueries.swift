import Foundation

enum GraphQLQueries {
    /// Shared field set for the PullRequest type. Used by both the inbox
    /// search query and the single-PR refresh query so the data shape stays
    /// in sync — `InboxResponse.PullRequestNode` is the single Swift mirror
    /// of these fields.
    private static let prFieldsFragment: String = """
    fragment PRFields on PullRequest {
      id number title body url isDraft additions deletions changedFiles
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
      autoMergeRequest { enabledBy { login } }
      reviewRequests(first: 10) {
        nodes { requestedReviewer { ... on User { login } } }
      }
      reviews(last: 20) {
        nodes { state author { login } submittedAt body }
      }
      comments(last: 10) {
        nodes { author { login } createdAt body }
      }
      commits(last: 1) {
        nodes {
          commit {
            oid
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

    /// Returns up to 50 open PRs the viewer authored. Goes through the
    /// `viewer.pullRequests` connection — NOT the search index — so it
    /// keeps working when GitHub Search is lagging or returning empty
    /// results for `involves:@me` (a real outage we hit on 2026-04-27
    /// that wiped both My PRs and Inbox tabs because they share the
    /// search query). Cost ≈ 25 points.
    static let myPRs: String = """
    query MyPRs {
      viewer {
        login
        pullRequests(
          states: OPEN,
          first: 50,
          orderBy: { field: UPDATED_AT, direction: DESC }
        ) {
          nodes { ...PRFields }
        }
      }
      rateLimit { remaining cost resetAt }
    }
    \(prFieldsFragment)
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
