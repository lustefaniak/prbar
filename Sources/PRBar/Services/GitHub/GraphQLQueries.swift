import Foundation

enum GraphQLQueries {
    static let inbox: String = """
    query Inbox {
      viewer { login }
      search(query: "is:pr is:open involves:@me archived:false", type: ISSUE, first: 50) {
        edges {
          node {
            ... on PullRequest {
              id number title body url isDraft additions deletions changedFiles
              repository { nameWithOwner }
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
          }
        }
      }
      rateLimit { remaining cost resetAt }
    }
    """
}
