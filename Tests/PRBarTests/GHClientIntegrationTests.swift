import XCTest
@testable import PRBar

/// Integration tests that hit the real `gh` CLI + GitHub API.
///
/// These catch the class of bugs that fixture-based unit tests can't:
/// schema drift (e.g. removed/renamed fields), `gh` flag changes, auth
/// state issues. Skipped automatically when `gh` isn't installed or
/// authenticated, so a fresh checkout / CI without secrets doesn't fail.
final class GHClientIntegrationTests: XCTestCase {
    private func skipIfGHUnavailable() async throws {
        guard let ghPath = ExecutableResolver.find("gh") else {
            throw XCTSkip("gh not installed; skipping integration test.")
        }
        let result = try await ProcessRunner.run(
            executable: ghPath,
            args: ["auth", "status"]
        )
        guard result.succeeded else {
            throw XCTSkip(
                "gh not authenticated; skipping. stderr: \(result.stderrString ?? "")"
            )
        }
    }

    /// Submits the production inbox query and decodes the response.
    /// Catches the "Field 'X' doesn't exist on type 'Y'" class of bug at
    /// test time instead of at user-clicks-fetch time.
    func testInboxQueryParsesAgainstRealAPI() async throws {
        try await skipIfGHUnavailable()

        let client = try GHClient()
        let prs = try await client.fetchInbox()

        // Don't assert on count — user's open-PR list changes over time.
        // Just assert shape on whatever came back. Note: `.other` is a
        // valid role here — `involves:@me` returns PRs where I'm a past
        // commenter or past reviewer (not currently requested + not author).
        for pr in prs {
            XCTAssertFalse(pr.nodeId.isEmpty,    "empty nodeId on #\(pr.number)")
            XCTAssertFalse(pr.owner.isEmpty,     "empty owner on #\(pr.number)")
            XCTAssertFalse(pr.repo.isEmpty,      "empty repo on #\(pr.number)")
            XCTAssertGreaterThan(pr.number, 0)
            XCTAssertEqual(pr.url.scheme, "https")
            for check in pr.allCheckSummaries {
                XCTAssertFalse(check.name.isEmpty, "check has empty name on #\(pr.number)")
                XCTAssertTrue(
                    ["CheckRun", "StatusContext"].contains(check.typename),
                    "unexpected check typename '\(check.typename)' on #\(pr.number)"
                )
            }
        }
    }

    /// Confirms every CheckRun/StatusContext field referenced in
    /// GraphQLQueries.inbox actually exists in GitHub's schema today.
    /// Catches schema drift even if the current user's PRs don't happen
    /// to exercise a particular field.
    func testIntrospectionConfirmsCheckFieldsExist() async throws {
        try await skipIfGHUnavailable()
        let ghPath = ExecutableResolver.find("gh")!

        try await assertFieldsExist(
            on: "CheckRun",
            expected: ["name", "conclusion", "status", "detailsUrl", "summary"],
            ghPath: ghPath
        )
        try await assertFieldsExist(
            on: "StatusContext",
            expected: ["context", "state", "targetUrl", "description"],
            ghPath: ghPath
        )
    }

    private func assertFieldsExist(
        on typeName: String,
        expected: Set<String>,
        ghPath: String
    ) async throws {
        let query = "{ __type(name: \"\(typeName)\") { fields { name } } }"
        let result = try await ProcessRunner.run(
            executable: ghPath,
            args: ["api", "graphql", "-f", "query=\(query)"]
        )
        XCTAssertTrue(
            result.succeeded,
            "introspection of \(typeName) failed: \(result.stderrString ?? "")"
        )

        struct IntrospectResponse: Decodable {
            let data: DataNode
            struct DataNode: Decodable {
                let typeNode: TypeNode

                enum CodingKeys: String, CodingKey {
                    case typeNode = "__type"
                }
            }
            struct TypeNode: Decodable { let fields: [Field] }
            struct Field: Decodable { let name: String }
        }

        let resp = try JSONDecoder().decode(IntrospectResponse.self, from: result.stdout)
        let actual = Set(resp.data.typeNode.fields.map(\.name))
        let missing = expected.subtracting(actual)
        XCTAssertTrue(
            missing.isEmpty,
            "Fields used by PRBar but missing from \(typeName): \(missing.sorted())"
        )
    }
}
