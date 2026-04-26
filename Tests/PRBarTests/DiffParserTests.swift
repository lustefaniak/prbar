import XCTest
@testable import PRBar

final class DiffParserTests: XCTestCase {
    func testEmptyDiffYieldsNoHunks() {
        XCTAssertTrue(DiffParser.parse("").isEmpty)
    }

    func testSingleFileSingleHunk() {
        let diff = """
        diff --git a/foo.go b/foo.go
        index abc..def 100644
        --- a/foo.go
        +++ b/foo.go
        @@ -1,3 +1,4 @@
         package foo
        +import "log"

         func Bar() {}
        """
        let hunks = DiffParser.parse(diff)
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks[0].filePath, "foo.go")
        XCTAssertEqual(hunks[0].oldStart, 1)
        XCTAssertEqual(hunks[0].oldCount, 3)
        XCTAssertEqual(hunks[0].newStart, 1)
        XCTAssertEqual(hunks[0].newCount, 4)
        XCTAssertEqual(hunks[0].lines.count, 4)
        XCTAssertEqual(hunks[0].lines[0], .context("package foo"))
        XCTAssertEqual(hunks[0].lines[1], .added("import \"log\""))
    }

    func testMultipleFilesMultipleHunks() {
        let diff = """
        diff --git a/a.go b/a.go
        --- a/a.go
        +++ b/a.go
        @@ -10,2 +10,3 @@
         line 10
        +new line
         line 11
        diff --git a/b.go b/b.go
        --- a/b.go
        +++ b/b.go
        @@ -5,1 +5,1 @@
        -old
        +new
        @@ -20 +20 @@
        -gone
        +here
        """
        let hunks = DiffParser.parse(diff)
        XCTAssertEqual(hunks.count, 3)
        XCTAssertEqual(hunks[0].filePath, "a.go")
        XCTAssertEqual(hunks[1].filePath, "b.go")
        XCTAssertEqual(hunks[2].filePath, "b.go")
        // Single-line range with no count should default to count = 1.
        XCTAssertEqual(hunks[2].oldStart, 20)
        XCTAssertEqual(hunks[2].oldCount, 1)
        XCTAssertEqual(hunks[2].newStart, 20)
        XCTAssertEqual(hunks[2].newCount, 1)
    }

    func testRenamePreservesNewPath() {
        let diff = """
        diff --git a/old/path.go b/new/path.go
        similarity index 95%
        rename from old/path.go
        rename to new/path.go
        index abc..def 100644
        --- a/old/path.go
        +++ b/new/path.go
        @@ -1,1 +1,1 @@
        -old content
        +new content
        """
        let hunks = DiffParser.parse(diff)
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks[0].filePath, "new/path.go")
    }

    func testBinaryFilesAreSkipped() {
        let diff = """
        diff --git a/icon.png b/icon.png
        index abc..def 100644
        Binary files a/icon.png and b/icon.png differ
        diff --git a/foo.go b/foo.go
        --- a/foo.go
        +++ b/foo.go
        @@ -1 +1 @@
        -old
        +new
        """
        let hunks = DiffParser.parse(diff)
        XCTAssertEqual(hunks.count, 1, "binary file should be skipped")
        XCTAssertEqual(hunks[0].filePath, "foo.go")
    }

    func testNoNewlineMarkerSkipped() {
        let diff = """
        diff --git a/x.txt b/x.txt
        --- a/x.txt
        +++ b/x.txt
        @@ -1 +1 @@
        -old
        \\ No newline at end of file
        +new
        """
        let hunks = DiffParser.parse(diff)
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks[0].lines.count, 2, "the '\\ No newline' marker shouldn't appear as a diff line")
        XCTAssertEqual(hunks[0].lines[0], .removed("old"))
        XCTAssertEqual(hunks[0].lines[1], .added("new"))
    }

    func testEmptyContextLineHandled() {
        // Some diffs have a literal empty line as a context line (no leading
        // space). git is usually careful but `gh pr diff` sometimes drops it.
        let diff = """
        diff --git a/a b/a
        --- a/a
        +++ b/a
        @@ -1,3 +1,4 @@
         line one

         line three
        +line four
        """
        let hunks = DiffParser.parse(diff)
        XCTAssertEqual(hunks.count, 1)
        // 3 context + 1 added = 4 total
        XCTAssertEqual(hunks[0].lines.count, 4)
        XCTAssertEqual(hunks[0].lines[1], .context(""))
    }
}
