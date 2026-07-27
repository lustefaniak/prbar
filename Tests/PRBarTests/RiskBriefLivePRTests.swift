import XCTest
@testable import PRBar

/// Runs `RiskBrief` over the viewer's real open PRs and prints the ranking it
/// would put in each subreview's prompt. Not an assertion suite — a harness
/// for eyeballing whether the heuristic orders real diffs sensibly, which is
/// the only way to tell whether the weights are any good.
///
/// Gated behind a sentinel file because it needs `gh` auth, network, and a
/// full worktree checkout per PR. The sentinel doubles as its config so no
/// repo-specific setting is baked into this public repo:
///
/// ```sh
/// cat > /tmp/prbar-riskbrief-live <<'JSON'
/// {"repo": "owner/name",
///  "rootPatterns": ["services/*/", "web/"],
///  "minFilesPerSubreview": 10,
///  "collapseAboveSubreviewCount": 2,
///  "churnWindowDays": 90,
///  "churnHistoryDepth": 1000}
/// JSON
/// xcodebuild ... -only-testing:PRBarTests/RiskBriefLivePRTests test
/// ```
///
/// `rootPatterns` / `minFilesPerSubreview` / `collapseAboveSubreviewCount`
/// should mirror the repo's entry in your `RepoConfigStore`, so the split the
/// harness prints is the split production would produce. Everything else
/// falls back to `RepoConfig.default`.
final class RiskBriefLivePRTests: XCTestCase {

    private static let sentinel = "/tmp/prbar-riskbrief-live"

    struct Settings: Decodable {
        let repo: String
        var rootPatterns: [String] = []
        var minFilesPerSubreview: Int = 1
        var collapseAboveSubreviewCount: Int? = nil
        var churnWindowDays: Int = 90
        var churnHistoryDepth: Int = 1_000
        var maxPRs: Int = 25

        enum CodingKeys: String, CodingKey {
            case repo, rootPatterns, minFilesPerSubreview
            case collapseAboveSubreviewCount, churnWindowDays, churnHistoryDepth, maxPRs
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.repo = try c.decode(String.self, forKey: .repo)
            self.rootPatterns = (try? c.decode([String].self, forKey: .rootPatterns)) ?? []
            self.minFilesPerSubreview = (try? c.decode(Int.self, forKey: .minFilesPerSubreview)) ?? 1
            self.collapseAboveSubreviewCount = try? c.decodeIfPresent(Int.self, forKey: .collapseAboveSubreviewCount)
            self.churnWindowDays = (try? c.decode(Int.self, forKey: .churnWindowDays)) ?? 90
            self.churnHistoryDepth = (try? c.decode(Int.self, forKey: .churnHistoryDepth)) ?? 1_000
            self.maxPRs = (try? c.decode(Int.self, forKey: .maxPRs)) ?? 25
        }
    }

    private struct LivePR: Decodable {
        let number: Int
        let title: String
        let headRefOid: String
        let baseRefName: String
        let changedFiles: Int
        let additions: Int
        let deletions: Int
    }

    func testPrintRiskBriefForOpenPRs() async throws {
        guard let raw = FileManager.default.contents(atPath: Self.sentinel) else {
            throw XCTSkip("no \(Self.sentinel) — see the doc comment to enable")
        }
        let settings = try JSONDecoder().decode(Settings.self, from: raw)
        let parts = settings.repo.split(separator: "/")
        guard parts.count == 2 else {
            return XCTFail("repo must be owner/name, got \(settings.repo)")
        }
        let (owner, repo) = (String(parts[0]), String(parts[1]))

        var config = RepoConfig.default
        config.splitMode = .perSubfolder
        config.rootPatterns = settings.rootPatterns
        config.minFilesPerSubreview = settings.minFilesPerSubreview
        config.collapseAboveSubreviewCount = settings.collapseAboveSubreviewCount
        config.churnWindowDays = settings.churnWindowDays
        config.churnHistoryDepth = settings.churnHistoryDepth

        let prs = try await listOpenPRs(repo: settings.repo, limit: settings.maxPRs)
        print("\n===== RISK BRIEF over \(prs.count) open PR(s) in \(settings.repo) =====\n")

        let manager = RepoCheckoutManager()
        for pr in prs {
            let diff = try await gh(["pr", "diff", "\(pr.number)", "--repo", settings.repo])
            let subdiffs = MonorepoSplitter.split(diffText: diff, config: config, toolMode: .sandboxed)

            print("─── #\(pr.number) — \(pr.title)")
            print("    \(pr.changedFiles) files, +\(pr.additions)/-\(pr.deletions), "
                  + "\(subdiffs.count) subreview(s), diff \(diff.utf8.count) bytes")

            var handle: RepoCheckoutManager.Handle?
            do {
                handle = try await manager.provision(
                    owner: owner, repo: repo, headSha: pr.headRefOid,
                    subpath: "", baseRef: pr.baseRefName,
                    historyDepth: settings.churnHistoryDepth
                )
            } catch {
                print("    provision failed (\(error)) — churn and marker scan skipped")
            }
            defer { if let handle { Task { await manager.release(handle) } } }

            var churn: ChurnWindow?
            var marked: Set<String> = []
            if let handle {
                churn = await GitChurn.fetch(
                    worktree: handle.worktreePath, windowDays: settings.churnWindowDays
                )
                marked = await GeneratedCodeScanner.scan(
                    paths: subdiffs.flatMap(\.filePaths), in: handle.worktreePath
                )
            }
            if let churn {
                print("    churn window: \(churn.commitsObserved) commits / ~\(churn.spanDays) days"
                      + " — usable: \(churn.isUsable)")
            } else {
                print("    churn window: unavailable")
            }
            if !marked.isEmpty {
                print("    marker-detected generated files: \(marked.count)")
            }

            for subdiff in subdiffs {
                let brief = RiskBrief.compute(
                    subdiff: subdiff, churn: churn, markedGenerated: marked
                )
                let label = subdiff.subpath.isEmpty ? "<root>" : subdiff.subpath
                print("    ── subreview `\(label)` (\(subdiff.filePaths.count) files)")
                for row in brief.rows {
                    let reasons = row.reasons.isEmpty ? "—" : row.reasons.joined(separator: "; ")
                    print(String(format: "       %.3f  %@  (+%d/-%d)  %@",
                                 row.score, row.path, row.addedLines, row.removedLines, reasons))
                }
                if brief.changesSourceWithoutAnyTest {
                    print("       [changes source, no test files]")
                }
            }
            print("")
        }
        print("===== END =====\n")
    }

    // MARK: - gh

    private func listOpenPRs(repo: String, limit: Int) async throws -> [LivePR] {
        let json = try await gh([
            "pr", "list", "--repo", repo, "--author", "@me", "--state", "open",
            "--limit", "\(limit)",
            "--json", "number,title,headRefOid,baseRefName,changedFiles,additions,deletions",
        ])
        return try JSONDecoder().decode([LivePR].self, from: Data(json.utf8))
    }

    private func gh(_ args: [String]) async throws -> String {
        guard let path = ExecutableResolver.find("gh") else {
            throw XCTSkip("gh not installed")
        }
        let result = try await ProcessRunner.run(executable: path, args: args)
        guard result.succeeded else {
            throw XCTSkip("gh \(args.first ?? "") failed: \((result.stderrString ?? "").prefix(300))")
        }
        return result.stdoutString ?? ""
    }
}
