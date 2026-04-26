import XCTest
@testable import PRBar

final class MonorepoSplitterTests: XCTestCase {
    func testEmptyDiffYieldsNoSubdiffs() {
        XCTAssertTrue(MonorepoSplitter.split(diffText: "").isEmpty)
    }

    func testSingleFileYieldsOneSubdiffAtRepoRoot() {
        let diff = """
        diff --git a/foo.go b/foo.go
        --- a/foo.go
        +++ b/foo.go
        @@ -1 +1 @@
        -old
        +new
        """
        let subs = MonorepoSplitter.split(diffText: diff)
        XCTAssertEqual(subs.count, 1)
        XCTAssertEqual(subs[0].subpath, "")
        XCTAssertEqual(subs[0].hunks.count, 1)
        XCTAssertEqual(subs[0].hunks[0].filePath, "foo.go")
    }

    func testMultiFileWithDefaultConfigStaysAtRoot() {
        // Default config has no rootPatterns; every hunk routes to the
        // unmatched bucket, collapsed into one repo-root Subdiff.
        let diff = """
        diff --git a/kernel-billing/log.go b/kernel-billing/log.go
        --- a/kernel-billing/log.go
        +++ b/kernel-billing/log.go
        @@ -1 +1 @@
        -old
        +new
        diff --git a/lib/auth/token.go b/lib/auth/token.go
        --- a/lib/auth/token.go
        +++ b/lib/auth/token.go
        @@ -1 +1 @@
        -old
        +new
        """
        let subs = MonorepoSplitter.split(diffText: diff)
        XCTAssertEqual(subs.count, 1)
        XCTAssertEqual(subs[0].subpath, "")
    }

    // MARK: - real config

    func testGetsynqCloudSplitsByRoot() {
        let diff = """
        diff --git a/kernel-billing/audit/log.go b/kernel-billing/audit/log.go
        --- a/kernel-billing/audit/log.go
        +++ b/kernel-billing/audit/log.go
        @@ -1 +1 @@
        -a
        +b
        diff --git a/lib/auth/token.go b/lib/auth/token.go
        --- a/lib/auth/token.go
        +++ b/lib/auth/token.go
        @@ -1 +1 @@
        -a
        +b
        diff --git a/README.md b/README.md
        --- a/README.md
        +++ b/README.md
        @@ -1 +1 @@
        -a
        +b
        """
        let subs = MonorepoSplitter.split(diffText: diff, config: .getsynqCloud)

        let bySubpath = Dictionary(uniqueKeysWithValues: subs.map { ($0.subpath, $0) })
        XCTAssertNotNil(bySubpath["kernel-billing"], "kernel-* should resolve to kernel-billing")
        XCTAssertNotNil(bySubpath["lib/auth"], "lib/* should resolve to lib/auth")
        XCTAssertNotNil(bySubpath[""], "README.md should land in repo-root unmatched bucket")
    }

    func testFanoutCapTailMergesSmallestIntoUnmatched() {
        // 5 distinct kernel modules with the cap = 4 → smallest one tail-
        // merges into the unmatched (root) bucket. We arrange counts so
        // kernel-d is the smallest.
        let diff = makeMultiKernelDiff(filesPerKernel: [
            "kernel-a": 3, "kernel-b": 3, "kernel-c": 3, "kernel-d": 1, "kernel-e": 2,
        ])
        let subs = MonorepoSplitter.split(diffText: diff, config: .getsynqCloud)
        let names = subs.map(\.subpath).filter { !$0.isEmpty }.sorted()
        XCTAssertFalse(names.contains("kernel-d"), "smallest bucket should be tail-merged out")
        XCTAssertLessThanOrEqual(subs.count, 4, "fanout cap is 4")
    }

    func testSkipReviewStrategyDropsUnmatched() {
        let diff = """
        diff --git a/README.md b/README.md
        --- a/README.md
        +++ b/README.md
        @@ -1 +1 @@
        -a
        +b
        """
        var cfg = RepoConfig.default
        cfg.rootPatterns = ["kernel-*"]
        cfg.unmatchedStrategy = .skipReview
        cfg.maxParallelSubreviews = 4
        let subs = MonorepoSplitter.split(diffText: diff, config: cfg)
        XCTAssertTrue(subs.isEmpty)
    }

    func testGroupAsOtherBucket() {
        let diff = """
        diff --git a/README.md b/README.md
        --- a/README.md
        +++ b/README.md
        @@ -1 +1 @@
        -a
        +b
        """
        var cfg = RepoConfig.default
        cfg.rootPatterns = ["kernel-*"]
        cfg.unmatchedStrategy = .groupAsOther
        cfg.maxParallelSubreviews = 4
        let subs = MonorepoSplitter.split(diffText: diff, config: cfg)
        XCTAssertEqual(subs.map(\.subpath), ["<other>"])
    }

    func testExcludedReturnsNoSubdiffs() {
        let diff = """
        diff --git a/foo.go b/foo.go
        --- a/foo.go
        +++ b/foo.go
        @@ -1 +1 @@
        -a
        +b
        """
        var cfg = RepoConfig.default
        cfg.excluded = true
        XCTAssertTrue(MonorepoSplitter.split(diffText: diff, config: cfg).isEmpty)
    }

    func testSplitModeSingleIgnoresRootPatterns() {
        // Even with rootPatterns set, .single forces one repo-root subdiff.
        let diff = """
        diff --git a/kernel-billing/log.go b/kernel-billing/log.go
        --- a/kernel-billing/log.go
        +++ b/kernel-billing/log.go
        @@ -1 +1 @@
        -a
        +b
        diff --git a/lib/auth/token.go b/lib/auth/token.go
        --- a/lib/auth/token.go
        +++ b/lib/auth/token.go
        @@ -1 +1 @@
        -a
        +b
        """
        var cfg = RepoConfig.getsynqCloud
        cfg.splitMode = .single
        let subs = MonorepoSplitter.split(diffText: diff, config: cfg)
        XCTAssertEqual(subs.count, 1)
        XCTAssertEqual(subs[0].subpath, "")
    }

    func testCollapseAboveThresholdMergesIntoOneRootReview() {
        // Three kernel modules, threshold 2 → collapse to a single root.
        let diff = makeMultiKernelDiff(filesPerKernel: [
            "kernel-a": 2, "kernel-b": 2, "kernel-c": 2,
        ])
        var cfg = RepoConfig.getsynqCloud
        cfg.collapseAboveSubreviewCount = 2
        cfg.maxParallelSubreviews = 8
        let subs = MonorepoSplitter.split(diffText: diff, config: cfg)
        XCTAssertEqual(subs.count, 1)
        XCTAssertEqual(subs[0].subpath, "")
    }

    func testCollapseBelowThresholdLeavesSplitAlone() {
        let diff = makeMultiKernelDiff(filesPerKernel: [
            "kernel-a": 2, "kernel-b": 2,
        ])
        var cfg = RepoConfig.getsynqCloud
        cfg.collapseAboveSubreviewCount = 5
        let subs = MonorepoSplitter.split(diffText: diff, config: cfg)
        XCTAssertGreaterThanOrEqual(subs.count, 2)
    }

    func testConfigMatchPicksGetsynqCloud() {
        let cfg = MonorepoConfig.match(owner: "getsynq", repo: "cloud")
        XCTAssertEqual(cfg.repoGlobs, ["getsynq/cloud"])
    }

    func testConfigMatchFallsBackToDefault() {
        let cfg = MonorepoConfig.match(owner: "someone", repo: "elsewhere")
        XCTAssertEqual(cfg.rootPatterns, [])
    }

    // MARK: - helpers

    private func makeMultiKernelDiff(filesPerKernel: [String: Int]) -> String {
        var s = ""
        for (kernel, n) in filesPerKernel {
            for i in 0..<n {
                let path = "\(kernel)/file\(i).go"
                s += """
                diff --git a/\(path) b/\(path)
                --- a/\(path)
                +++ b/\(path)
                @@ -1 +1 @@
                -a
                +b

                """
            }
        }
        return s
    }
}
