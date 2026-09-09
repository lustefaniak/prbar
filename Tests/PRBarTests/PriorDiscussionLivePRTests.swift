import XCTest
@testable import PRBar

/// Prints the prompt's prior-discussion section for one real PR, so the
/// framing can be judged against a conversation that actually happened.
/// Not an assertion suite — the section's job is to stop a model re-raising
/// a settled finding, and fixtures can't tell you whether it reads that way.
///
/// Gated behind a sentinel file that doubles as its config, so no
/// repo-specific setting is baked into this public repo:
///
/// ```sh
/// echo '{"repo": "owner/name", "number": 123}' > /tmp/prbar-prior-discussion-live
/// xcodebuild ... -only-testing:PRBarTests/PriorDiscussionLivePRTests test
/// ```
final class PriorDiscussionLivePRTests: XCTestCase {

    private static let sentinel = "/tmp/prbar-prior-discussion-live"

    private struct Settings: Decodable {
        let repo: String
        let number: Int
    }

    func testPrintPriorDiscussionForOnePR() async throws {
        guard let raw = FileManager.default.contents(atPath: Self.sentinel) else {
            throw XCTSkip("no \(Self.sentinel) — see the doc comment to enable")
        }
        let settings = try JSONDecoder().decode(Settings.self, from: raw)
        let parts = settings.repo.split(separator: "/")
        guard parts.count == 2 else {
            return XCTFail("repo must be owner/name, got \(settings.repo)")
        }
        let (owner, repo) = (String(parts[0]), String(parts[1]))
        guard ExecutableResolver.find("gh") != nil else { throw XCTSkip("gh not installed") }

        let gh = try GHClient()
        let pr = try await gh.fetchPR(owner: owner, repo: repo, number: settings.number)
        let page = try await gh.fetchReviewThreads(owner: owner, repo: repo, number: settings.number)
        let diff = try await gh.fetchDiff(owner: owner, repo: repo, number: settings.number)
        let subdiffs = MonorepoSplitter.split(
            diffText: diff, config: RepoConfig.default.resolved(), toolMode: .sandboxed
        )

        print("\n===== PRIOR DISCUSSION — \(settings.repo)#\(settings.number) =====")
        print("head \(pr.headSha.prefix(7)) | author @\(pr.author) | viewer @\(page.viewerLogin)")
        print("\(pr.humanReviews.count) review(s), \(page.threads.count) thread(s), "
              + "\(subdiffs.count) subreview(s)\n")

        for subdiff in subdiffs {
            let paths = Set(subdiff.filePaths)
            let mine = page.threads.filter { !$0.path.isEmpty && paths.contains($0.path) }
            let label = subdiff.subpath.isEmpty ? "<root>" : subdiff.subpath
            let prompt = ContextAssembler.buildUserPrompt(
                pr: pr, subdiff: subdiff, diffText: diff,
                priorThreads: mine, ciFailures: [], toolMode: .sandboxed
            )
            print("─── subreview `\(label)`: \(mine.count) of \(page.threads.count) thread(s) "
                  + "in scope, prompt \(prompt.utf8.count) bytes")
            print(Self.section(named: "## Prior review discussion", in: prompt)
                  ?? "    (section absent)")
            print("")
        }
        print("===== END =====\n")
    }

    /// The section as it lands in the prompt, up to the next heading. Read
    /// out of the assembled prompt rather than off a widened accessor, so
    /// the harness also shows where in the prompt it sits.
    private static func section(named heading: String, in prompt: String) -> String? {
        guard let start = prompt.range(of: heading) else { return nil }
        let rest = prompt[start.upperBound...]
        guard let next = rest.range(of: "\n## ") else { return heading + rest }
        return heading + rest[..<next.lowerBound]
    }
}
