import Foundation

/// Recent-commit history observed for a repo checkout, used for the churn
/// term of `RiskBrief`.
///
/// `commitsByPath` counts *commits touching a path*, not lines changed —
/// the same definition code-review-graph uses, and the one that lets us
/// read it off a blobless clone: `git log --name-only` diffs trees only,
/// so no blob ever faults in (verified with `GIT_NO_LAZY_FETCH=1`).
struct ChurnWindow: Sendable, Hashable, Codable {
    /// Repo-relative path → number of commits in the window that touched it.
    let commitsByPath: [String: Int]
    /// Commits actually observed. `RepoCheckoutManager` clones with
    /// `--depth=50`, so this is frequently far short of the requested
    /// window — hence `isUsable`.
    let commitsObserved: Int
    /// Days between the oldest and newest observed commit.
    let spanDays: Int

    /// Below this many commits the per-file counts don't discriminate — one
    /// or two touches each, which is not a hotness signal.
    static let minCommits = 12

    /// Gated on commit count alone, deliberately not on `spanDays`. An
    /// earlier version also required a 7-day span, which on a busy monorepo
    /// rejected every window: `--depth=50` there covers ~3 days, so the
    /// repos where churn discriminates most were exactly the ones it was
    /// switched off for. A short span makes this "hot right now" rather than
    /// "chronically hot" — a different signal, still a useful one, and the
    /// rendered summary states the observed span so it isn't oversold.
    var isUsable: Bool { commitsObserved >= Self.minCommits }

    func commits(for path: String) -> Int { commitsByPath[path] ?? 0 }
}

/// Deterministic pre-scan that tells the AI judge **where to spend its
/// limited lookups** on a subreview. Routing only — a high rank means "look
/// here first", never "this is wrong". Nothing here is a finding, and the
/// prompt says so explicitly, because a keyword-and-churn heuristic that
/// leaks into the verdict is exactly the noise `system-base.md` spends its
/// length suppressing.
///
/// Adapted from code-review-graph's `compute_risk_score`, minus the parts
/// that need a persistent code graph (call-graph breadth, community
/// crossing, execution-flow participation). What survives is the subset
/// computable from the diff plus `git log` on the checkout we already have.
struct RiskBrief: Sendable, Hashable, Codable {
    /// How much a file's content is worth reading closely, independent of
    /// what changed in it.
    enum FileClass: String, Sendable, Codable {
        case source
        case test
        /// Schemas, migrations, dependency manifests, CI and service config:
        /// hand-written and worth reading (a destructive migration is a real
        /// blocker) but not unit-testable, so the test-pairing term must not
        /// apply. Without this class a two-line `kernel.yaml` edit outranked
        /// a 529-line new service purely for having no `_test.go` beside it.
        case manifest
        /// Machine-produced or vendored: lockfiles, protobuf output, mocks,
        /// `vendor/`. Reviewing the generator's input beats reading these.
        case generated
        /// Prose. Wrong docs matter, but not the way wrong code does.
        case docs

        /// Primary sort key: hand-written files first, machine-produced and
        /// prose after, whatever their scores.
        var sortRank: Int {
            switch self {
            case .source, .manifest, .test: return 0
            case .generated, .docs:         return 1
            }
        }
    }

    struct FileRow: Sendable, Hashable, Codable {
        let path: String
        /// 0.0–1.0, for ordering only. Deliberately **not** rendered into
        /// the prompt: a printed number invites the model to treat the
        /// heuristic as evidence.
        let score: Double
        /// Rendered verbatim after the path, comma-joined. Each entry
        /// states an observation, not a judgement.
        let reasons: [String]
        let addedLines: Int
        let removedLines: Int
        let fileClass: FileClass
    }

    /// Every file in the subreview, highest score first.
    let rows: [FileRow]
    /// True when the subreview changes at least one source file and no test
    /// file at all. A per-file signal would over-fire; the PR-wide one is
    /// the honest version of "this change ships untested".
    let changesSourceWithoutAnyTest: Bool
    /// Nil when the churn term was unavailable or too thin to use.
    let churnSummary: String?

    var isEmpty: Bool { rows.isEmpty }

    /// Rows worth putting in front of the model, in order. Generated and
    /// docs files are listed separately (and briefly) so they don't pad the
    /// priority list.
    var priorityRows: [FileRow] {
        rows.filter { $0.fileClass != .generated && $0.fileClass != .docs }
    }

    var lowSignalRows: [FileRow] {
        rows.filter { $0.fileClass == .generated || $0.fileClass == .docs }
    }

    // MARK: - scoring weights

    /// Caps, mirroring code-review-graph's additive-with-ceilings shape.
    /// They don't sum to 1.0 — the score is an ordering key, not a
    /// probability, so normalising would imply a precision we don't have.
    private static let churnWeight = 0.25
    private static let churnSaturationCommits = 10.0
    private static let missingTestWeight = 0.25
    private static let sensitiveWeight = 0.20
    private static let sizeWeight = 0.25
    private static let sizeSaturationLines = 200.0

    /// The missing-test term scales with how much changed rather than being
    /// flat. Measured against real PRs, a flat bonus put every one-line
    /// untested config edit above every large well-tested file — the term
    /// carried the ranking instead of contributing to it. An untested
    /// two-line change is not a place to start reading; an untested 300-line
    /// file is.
    private static let missingTestSaturationLines = 80.0

    /// Below this fraction of the missing-test term, the observation isn't
    /// worth a line in the prompt even though it still nudges the score.
    private static let missingTestMentionFloor = 0.5

    /// Generated and docs files keep a token score so ordering stays
    /// deterministic, but sink below anything real.
    private static let lowSignalDamping = 0.15

    /// Path fragments where a bug is a security incident rather than a
    /// defect. Deliberately much tighter than code-review-graph's list,
    /// which includes `query`, `execute`, `request`, `http`, `connect` and
    /// `validate` — those match most backend files and so rank nothing.
    static let sensitiveFragments: [String] = [
        "auth", "login", "password", "passwd", "secret", "credential",
        "token", "session", "oauth", "jwt", "crypt", "cipher", "hmac",
        "signature", "permission", "privilege", "tenant", "acl", "rbac",
        "sanitiz", "csrf", "xss",
    ]

    // MARK: - compute

    /// Build the brief for one subreview. Pure — `churn` and
    /// `markedGenerated` are the inputs that needed I/O, and both arrive
    /// already resolved.
    ///
    /// `markedGenerated` is the set of paths whose file head carries a
    /// generated marker (see `GeneratedCodeScanner`). It outranks the
    /// filename heuristics: `wire_gen.go` and `queries.sql.go` look like
    /// ordinary source by name and are anything but.
    static func compute(
        subdiff: Subdiff,
        churn: ChurnWindow? = nil,
        markedGenerated: Set<String> = []
    ) -> RiskBrief {
        let paths = subdiff.filePaths
        guard !paths.isEmpty else {
            return RiskBrief(rows: [], changesSourceWithoutAnyTest: false, churnSummary: nil)
        }

        var added: [String: Int] = [:]
        var removed: [String: Int] = [:]
        for hunk in subdiff.hunks {
            for line in hunk.lines {
                switch line {
                case .added:   added[hunk.filePath, default: 0] += 1
                case .removed: removed[hunk.filePath, default: 0] += 1
                case .context: break
                }
            }
        }

        let classes = Dictionary(uniqueKeysWithValues: paths.map { path in
            (path, markedGenerated.contains(path) ? FileClass.generated : classify(path))
        })
        let usableChurn = (churn?.isUsable == true) ? churn : nil
        // Test-file stems present anywhere in the subreview, so a source
        // file's paired test counts even when it lives in a sibling tree
        // (`src/foo.ts` + `test/foo.test.ts`).
        let testedStems = Set(
            paths.filter { classes[$0] == .test }.map { normalizedStem($0) }
        )

        var rows: [FileRow] = []
        for path in paths {
            let fileClass = classes[path] ?? .source
            let adds = added[path] ?? 0
            let dels = removed[path] ?? 0
            var score = 0.0
            var reasons: [String] = []

            if let churn = usableChurn {
                let commits = churn.commits(for: path)
                if commits > 0 {
                    score += min(Double(commits) / churnSaturationCommits, 1.0) * churnWeight
                }
                // Only worth saying when the file stands out against the
                // window; "1 of 40 commits" is every file in the diff.
                if commits >= 3 {
                    reasons.append("touched by \(commits) of the last \(churn.commitsObserved) commits")
                }
            }

            let churnedLines = Double(adds + dels)

            if fileClass == .source, !hasPairedTest(path, in: testedStems) {
                let scale = min(churnedLines / missingTestSaturationLines, 1.0)
                score += missingTestWeight * scale
                if scale >= missingTestMentionFloor {
                    reasons.append("no matching test file changed in this subreview")
                }
            }

            // Test files are worth reading, but boosting them for a sensitive
            // path just floats `token_test.go` above the code it covers.
            if fileClass != .test, let hit = sensitiveHit(path) {
                score += sensitiveWeight
                reasons.append("path matches sensitive area (\(hit))")
            }

            if churnedLines > 0 {
                score += min(churnedLines / sizeSaturationLines, 1.0) * sizeWeight
            }

            if fileClass == .generated || fileClass == .docs {
                score *= lowSignalDamping
                if fileClass == .docs {
                    reasons = ["documentation"]
                } else if markedGenerated.contains(path) {
                    // Worth distinguishing: the marker is the file itself
                    // saying so, where the filename version is our guess.
                    reasons = ["marked auto-generated (do-not-edit header)"]
                } else {
                    reasons = ["generated or vendored"]
                }
            }

            rows.append(FileRow(
                path: path,
                score: (score * 10_000).rounded() / 10_000,
                reasons: reasons,
                addedLines: adds,
                removedLines: dels,
                fileClass: fileClass
            ))
        }

        // Low-signal files sort below everything else by class, not by score
        // alone. Damping a huge generated file's score isn't enough — a
        // 1,300-line `go.sum` still outscored a four-line source edit, and no
        // amount of lockfile churn should outrank real code. Within a class,
        // score desc, then path asc so equal scores don't reshuffle between
        // runs (the brief lands in the prompt, and a prompt that changes for
        // no reason busts the review cache).
        rows.sort { lhs, rhs in
            let lr = lhs.fileClass.sortRank, rr = rhs.fileClass.sortRank
            if lr != rr { return lr < rr }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.path < rhs.path
        }

        let hasSource = classes.values.contains(.source)
        let hasTest = classes.values.contains(.test)
        var churnSummary: String? = nil
        if let churn = usableChurn {
            churnSummary = "\(churn.commitsObserved) commits over ~\(churn.spanDays) days"
        }

        return RiskBrief(
            rows: rows,
            changesSourceWithoutAnyTest: hasSource && !hasTest,
            churnSummary: churnSummary
        )
    }

    // MARK: - classification

    static func classify(_ path: String) -> FileClass {
        let lower = path.lowercased()
        let name = (lower as NSString).lastPathComponent

        // Order matters: a lockfile named `package-lock.json` under a
        // `test/` fixture dir is still generated, and a generated file
        // named `foo_test.pb.go` is still generated.
        if isGenerated(path: lower, name: name) { return .generated }
        if isTest(path: lower, name: name) { return .test }
        if isDocs(path: lower, name: name) { return .docs }
        if isManifest(path: lower, name: name) { return .manifest }
        return .source
    }

    private static let manifestExtensions: Set<String> = [
        "sql", "proto", "yaml", "yml", "json", "toml", "ini", "cfg", "conf",
        "tf", "tfvars", "graphql", "gql", "mod", "properties", "plist",
        "entitlements", "xcconfig", "gradle", "cmake",
    ]

    private static let manifestNames: Set<String> = [
        "dockerfile", "makefile", "procfile", "gemfile", "podfile",
        "brewfile", "justfile", "rakefile", ".env", "project.yml",
    ]

    private static func isManifest(path: String, name: String) -> Bool {
        if manifestNames.contains(name) { return true }
        if name.hasPrefix("dockerfile.") { return true }
        return manifestExtensions.contains((name as NSString).pathExtension)
    }

    private static let generatedNames: Set<String> = [
        "go.sum", "yarn.lock", "package-lock.json", "pnpm-lock.yaml",
        "cargo.lock", "gemfile.lock", "composer.lock", "poetry.lock",
        "uv.lock", "podfile.lock", "package.resolved", "flake.lock",
    ]

    private static let generatedFragments: [String] = [
        ".pb.go", ".pb.gw.go", "_pb2.py", "_pb2_grpc.py", ".pb.swift",
        ".generated.", "_generated.", ".g.dart", ".freezed.dart",
        "_mock.go", "mock_", ".snap", ".pbxproj", ".xcworkspacedata",
    ]

    private static let generatedDirs: [String] = [
        "/vendor/", "/node_modules/", "/third_party/", "/.yarn/",
        "/generated/", "/__generated__/", "/mocks/", "/gen/",
    ]

    private static func isGenerated(path: String, name: String) -> Bool {
        if generatedNames.contains(name) { return true }
        if generatedFragments.contains(where: { name.contains($0) }) { return true }
        // Leading-slash sentinel so `vendor/x.go` matches the same way
        // `a/vendor/x.go` does.
        let padded = "/" + path
        return generatedDirs.contains { padded.contains($0) }
    }

    private static func isTest(path: String, name: String) -> Bool {
        if name.hasPrefix("test_") || name.hasPrefix("conftest.") { return true }
        for fragment in ["_test.", ".test.", "_spec.", ".spec.", "test.", "tests."] where name.contains(fragment) {
            return true
        }
        // `FooTests.swift`, `FooTest.java` — stem ends in Test/Tests.
        let stem = (name as NSString).deletingPathExtension
        if stem.hasSuffix("test") || stem.hasSuffix("tests") { return true }
        let padded = "/" + path
        for dir in ["/test/", "/tests/", "/testdata/", "/spec/", "/__tests__/", "/e2e/"] where padded.contains(dir) {
            return true
        }
        return false
    }

    private static let docExtensions: Set<String> = ["md", "mdx", "markdown", "rst", "txt", "adoc"]

    private static func isDocs(path: String, name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        if docExtensions.contains(ext) { return true }
        if ["license", "notice", "authors", "changelog"].contains((name as NSString).deletingPathExtension) {
            return true
        }
        return ("/" + path).contains("/docs/")
    }

    /// Filename stem with test affixes stripped, for pairing a source file
    /// with its test. `audit/log.go` and `audit/log_test.go` both reduce to
    /// `log`; `Sources/Foo.swift` and `Tests/FooTests.swift` both to `foo`.
    static func normalizedStem(_ path: String) -> String {
        var stem = (((path as NSString).lastPathComponent) as NSString)
            .deletingPathExtension
            .lowercased()
        // `foo.test.ts` → deletingPathExtension leaves `foo.test`.
        for suffix in [".test", ".spec", "_test", "_spec", "-test", "-spec", "tests", "test", "spec"]
        where stem.hasSuffix(suffix) && stem.count > suffix.count {
            stem = String(stem.dropLast(suffix.count))
            break
        }
        if stem.hasPrefix("test_") { stem = String(stem.dropFirst(5)) }
        return stem.trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
    }

    /// True when some changed test file covers `path`.
    ///
    /// Exact stem equality is not enough: Go's `_integration_test.go`,
    /// `_query_test.go` and `_slack_test.go` suffixes are common, and on real
    /// PRs they made well-tested files report as untested. So a test stem
    /// also pairs when the source stem is its leading `_`/`-`/`.`-delimited
    /// component — `revalidate` pairs with `revalidate_integration`, while
    /// `log` still does not pair with `logger`.
    static func hasPairedTest(_ path: String, in testedStems: Set<String>) -> Bool {
        let stem = normalizedStem(path)
        guard !stem.isEmpty else { return false }
        if testedStems.contains(stem) { return true }
        return testedStems.contains { testStem in
            leadingComponent(testStem) == stem
        }
    }

    private static func leadingComponent(_ stem: String) -> String {
        String(stem.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == "." }).first ?? "")
    }

    /// First sensitive fragment the path matches, or nil.
    static func sensitiveHit(_ path: String) -> String? {
        let lower = path.lowercased()
        return sensitiveFragments.first { lower.contains($0) }
    }
}
