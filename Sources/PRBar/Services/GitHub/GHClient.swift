import Foundation

actor GHClient {
    enum GHError: Error, LocalizedError, Sendable {
        case ghNotFound
        case execFailed(stderr: String, exitCode: Int32)
        case decodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .ghNotFound:
                return "gh CLI not found. Install via: brew install gh, then `gh auth login`."
            case .execFailed(let stderr, let code):
                let snippet = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return "gh exited \(code): \(snippet.prefix(400))"
            case .decodingFailed(let msg):
                return "decode error: \(msg.prefix(400))"
            }
        }
    }

    private let executablePath: String

    init() throws {
        guard let path = ExecutableResolver.find("gh") else {
            throw GHError.ghNotFound
        }
        self.executablePath = path
    }

    func fetchInbox() async throws -> [InboxPR] {
        let result = try await ProcessRunner.run(
            executable: executablePath,
            args: ["api", "graphql", "-f", "query=\(GraphQLQueries.inbox)"]
        )

        guard result.succeeded else {
            throw GHError.execFailed(
                stderr: result.stderrString ?? "",
                exitCode: result.exitCode
            )
        }

        let response: InboxResponse
        do {
            response = try JSONDecoder().decode(InboxResponse.self, from: result.stdout)
        } catch {
            throw GHError.decodingFailed(String(describing: error))
        }

        let viewerLogin = response.data.viewer.login
        return response.data.search.edges.map {
            InboxPR(node: $0.node, viewerLogin: viewerLogin)
        }
    }

    /// Refresh a single PR. Costs ~1 GraphQL point vs ~25 for fetchInbox.
    func fetchPR(owner: String, repo: String, number: Int) async throws -> InboxPR {
        let result = try await ProcessRunner.run(
            executable: executablePath,
            args: [
                "api", "graphql",
                "-F", "owner=\(owner)",
                "-F", "name=\(repo)",
                "-F", "number=\(number)",
                "-f", "query=\(GraphQLQueries.singlePR)",
            ]
        )

        guard result.succeeded else {
            throw GHError.execFailed(
                stderr: result.stderrString ?? "",
                exitCode: result.exitCode
            )
        }

        let response: SinglePRResponse
        do {
            response = try JSONDecoder().decode(SinglePRResponse.self, from: result.stdout)
        } catch {
            throw GHError.decodingFailed(String(describing: error))
        }

        return InboxPR(
            node: response.data.repository.pullRequest,
            viewerLogin: response.data.viewer.login
        )
    }
}
