import XCTest
@testable import PRBar

final class InboxResponseTests: XCTestCase {
    func testDecodeMinimalPRWithCheckRun() throws {
        let json = """
        {
          "data": {
            "viewer": { "login": "lustefaniak" },
            "search": {
              "edges": [
                {
                  "node": {
                    "id": "PR_kwDO123",
                    "number": 42,
                    "title": "Add audit log to billing API",
                    "body": "Body text",
                    "url": "https://github.com/getsynq/cloud/pull/42",
                    "isDraft": false,
                    "additions": 120,
                    "deletions": 10,
                    "changedFiles": 5,
                    "repository": { "nameWithOwner": "getsynq/cloud" },
                    "author": { "login": "alice" },
                    "headRefName": "feat/audit",
                    "baseRefName": "main",
                    "mergeable": "MERGEABLE",
                    "mergeStateStatus": "CLEAN",
                    "reviewDecision": "APPROVED",
                    "autoMergeRequest": null,
                    "reviewRequests": {
                      "nodes": [
                        { "requestedReviewer": { "login": "lustefaniak" } }
                      ]
                    },
                    "reviews": { "nodes": [] },
                    "comments": { "nodes": [] },
                    "commits": {
                      "nodes": [
                        {
                          "commit": {
                            "oid": "abc123",
                            "statusCheckRollup": {
                              "state": "SUCCESS",
                              "contexts": {
                                "nodes": [
                                  {
                                    "__typename": "CheckRun",
                                    "name": "Test Suite",
                                    "conclusion": "SUCCESS",
                                    "status": "COMPLETED",
                                    "detailsUrl": "https://example.com",
                                    "summary": null
                                  }
                                ]
                              }
                            }
                          }
                        }
                      ]
                    }
                  }
                }
              ]
            },
            "rateLimit": { "remaining": 4900, "cost": 25, "resetAt": "2026-04-26T12:00:00Z" }
          }
        }
        """
        let data = Data(json.utf8)
        let response = try JSONDecoder().decode(InboxResponse.self, from: data)

        XCTAssertEqual(response.data.viewer.login, "lustefaniak")
        XCTAssertEqual(response.data.search.edges.count, 1)
        XCTAssertEqual(response.data.rateLimit.cost, 25)

        let node = response.data.search.edges[0].node
        XCTAssertEqual(node.number, 42)
        XCTAssertEqual(node.repository.nameWithOwner, "getsynq/cloud")

        let pr = InboxPR(node: node, viewerLogin: "lustefaniak")
        XCTAssertEqual(pr.role, .reviewRequested)
        XCTAssertEqual(pr.owner, "getsynq")
        XCTAssertEqual(pr.repo, "cloud")
        XCTAssertEqual(pr.number, 42)
        XCTAssertEqual(pr.checkRollupState, "SUCCESS")
        XCTAssertEqual(pr.allCheckSummaries.count, 1)
        XCTAssertEqual(pr.allCheckSummaries[0].name, "Test Suite")
        XCTAssertEqual(pr.allCheckSummaries[0].typename, "CheckRun")
        XCTAssertFalse(pr.hasAutoMerge)
    }

    func testRoleAuthoredWhenViewerIsAuthor() throws {
        let json = wrapNode(authorLogin: "lustefaniak", reviewerLogin: nil)
        let response = try JSONDecoder().decode(InboxResponse.self, from: Data(json.utf8))
        let pr = InboxPR(node: response.data.search.edges[0].node, viewerLogin: "lustefaniak")
        XCTAssertEqual(pr.role, .authored)
    }

    func testRoleBothWhenAuthorAndReviewer() throws {
        let json = wrapNode(authorLogin: "lustefaniak", reviewerLogin: "lustefaniak")
        let response = try JSONDecoder().decode(InboxResponse.self, from: Data(json.utf8))
        let pr = InboxPR(node: response.data.search.edges[0].node, viewerLogin: "lustefaniak")
        XCTAssertEqual(pr.role, .both)
    }

    func testTeamReviewerHasNilLoginAndDoesNotMatch() throws {
        // When requestedReviewer is a Team (not a User), the inline fragment
        // `... on User { login }` produces an empty object — login is absent/null.
        let json = """
        {
          "data": {
            "viewer": { "login": "lustefaniak" },
            "search": {
              "edges": [{ "node": \(prNodeFragment(authorLogin: "alice", reviewersJson: "[{ \"requestedReviewer\": {} }]")) }]
            },
            "rateLimit": { "remaining": 1, "cost": 1, "resetAt": "x" }
          }
        }
        """
        let response = try JSONDecoder().decode(InboxResponse.self, from: Data(json.utf8))
        let pr = InboxPR(node: response.data.search.edges[0].node, viewerLogin: "lustefaniak")
        XCTAssertEqual(pr.role, .other, "team-only review request shouldn't count as reviewRequested for me")
    }

    func testDecodeStatusContextLegacyShape() throws {
        // Older third-party CIs emit StatusContext, not CheckRun.
        // Our CheckSummary maps `context` → name and `state` → status when CheckRun fields are absent.
        let json = wrapNode(
            authorLogin: "alice",
            reviewerLogin: "lustefaniak",
            statusContextsJson: """
            [{
              "__typename": "StatusContext",
              "context": "ci/circleci",
              "state": "SUCCESS",
              "targetUrl": "https://circleci.com/...",
              "description": "Tests passed"
            }]
            """
        )
        let response = try JSONDecoder().decode(InboxResponse.self, from: Data(json.utf8))
        let pr = InboxPR(node: response.data.search.edges[0].node, viewerLogin: "lustefaniak")
        XCTAssertEqual(pr.allCheckSummaries.count, 1)
        XCTAssertEqual(pr.allCheckSummaries[0].typename, "StatusContext")
        XCTAssertEqual(pr.allCheckSummaries[0].name, "ci/circleci")
        XCTAssertEqual(pr.allCheckSummaries[0].status, "SUCCESS")
    }

    // MARK: - fixture helpers

    private func wrapNode(
        authorLogin: String,
        reviewerLogin: String?,
        statusContextsJson: String? = nil
    ) -> String {
        let reviewersJson: String
        if let reviewerLogin {
            reviewersJson = "[{ \"requestedReviewer\": { \"login\": \"\(reviewerLogin)\" } }]"
        } else {
            reviewersJson = "[]"
        }
        let contexts = statusContextsJson ?? """
        [{ "__typename": "CheckRun", "name": "ci", "conclusion": "SUCCESS", "status": "COMPLETED", "detailsUrl": null, "summary": null }]
        """
        return """
        {
          "data": {
            "viewer": { "login": "lustefaniak" },
            "search": { "edges": [{ "node": \(prNodeFragment(authorLogin: authorLogin, reviewersJson: reviewersJson, statusContextsJson: contexts)) }] },
            "rateLimit": { "remaining": 1, "cost": 1, "resetAt": "x" }
          }
        }
        """
    }

    private func prNodeFragment(
        authorLogin: String,
        reviewersJson: String,
        statusContextsJson: String = "[]"
    ) -> String {
        return """
        {
          "id": "PR_x",
          "number": 1,
          "title": "t",
          "body": "",
          "url": "https://github.com/o/r/pull/1",
          "isDraft": false,
          "additions": 1, "deletions": 0, "changedFiles": 1,
          "repository": { "nameWithOwner": "o/r" },
          "author": { "login": "\(authorLogin)" },
          "headRefName": "h", "baseRefName": "main",
          "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "reviewDecision": null,
          "autoMergeRequest": null,
          "reviewRequests": { "nodes": \(reviewersJson) },
          "reviews": { "nodes": [] },
          "comments": { "nodes": [] },
          "commits": {
            "nodes": [{
              "commit": {
                "oid": "x",
                "statusCheckRollup": {
                  "state": "SUCCESS",
                  "contexts": { "nodes": \(statusContextsJson) }
                }
              }
            }]
          }
        }
        """
    }
}
