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

    func testMultiFileYieldsOneSubdiffAtRepoRootForNow() {
        // Phase 2 trivial pass-through: even when files belong to different
        // subfolders, we return one Subdiff. Phase 4 will split.
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
        XCTAssertEqual(subs[0].hunks.map(\.filePath), [
            "kernel-billing/log.go",
            "lib/auth/token.go",
        ])
    }
}
