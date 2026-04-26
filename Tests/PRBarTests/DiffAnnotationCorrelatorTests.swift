import XCTest
@testable import PRBar

final class DiffAnnotationCorrelatorTests: XCTestCase {
    /// Minimal hunk:  newStart = 10
    ///   line idx 0 ctx     -> new 10
    ///   line idx 1 added   -> new 11
    ///   line idx 2 removed -> nil
    ///   line idx 3 added   -> new 12
    ///   line idx 4 ctx     -> new 13
    private func sampleHunk(file: String = "kernel-billing/log.go") -> Hunk {
        Hunk(
            filePath: file,
            oldStart: 100, oldCount: 3,
            newStart: 10, newCount: 4,
            lines: [
                .context("// a"),
                .added("// b"),
                .removed("// old"),
                .added("// c"),
                .context("// d"),
            ]
        )
    }

    func testNewLineNumbersSkipsRemoved() {
        let nums = DiffAnnotationCorrelator.newLineNumbers(for: sampleHunk())
        XCTAssertEqual(nums, [10, 11, nil, 12, 13])
    }

    func testOldLineNumbersSkipsAdded() {
        let nums = DiffAnnotationCorrelator.oldLineNumbers(for: sampleHunk())
        XCTAssertEqual(nums, [100, nil, 101, nil, 102])
    }

    func testCorrelateRangeCoversAddedAndContext() {
        let h = sampleHunk()
        let ann = DiffAnnotation(
            path: h.filePath,
            lineStart: 11, lineEnd: 12,
            severity: .warning,
            body: "watch this"
        )
        let hits = DiffAnnotationCorrelator.correlate(hunks: [h], annotations: [ann])
        let fileHits = try? XCTUnwrap(hits[h.filePath])
        XCTAssertEqual(fileHits?.count, 2)   // line 11 (added) and line 12 (added)
        XCTAssertEqual(fileHits?.map(\.lineIndex).sorted(), [1, 3])
    }

    func testRemovedLineNeverHit() {
        let h = sampleHunk()
        // Annotation at new lines 10..13 — covers everything except removed.
        let ann = DiffAnnotation(
            path: h.filePath,
            lineStart: 10, lineEnd: 13,
            severity: .info,
            body: "all"
        )
        let hits = DiffAnnotationCorrelator.correlate(hunks: [h], annotations: [ann])
        let lineIndices = (hits[h.filePath] ?? []).map(\.lineIndex).sorted()
        XCTAssertEqual(lineIndices, [0, 1, 3, 4])      // index 2 (removed) excluded
    }

    func testWrongPathProducesNoHits() {
        let h = sampleHunk()
        let ann = DiffAnnotation(
            path: "lib/auth/token.go",
            lineStart: 11, lineEnd: 11,
            severity: .blocker,
            body: "no"
        )
        let hits = DiffAnnotationCorrelator.correlate(hunks: [h], annotations: [ann])
        XCTAssertTrue(hits.isEmpty)
    }

    func testOutOfRangeProducesNoHits() {
        let h = sampleHunk()
        let ann = DiffAnnotation(
            path: h.filePath,
            lineStart: 200, lineEnd: 250,
            severity: .info,
            body: "off"
        )
        let hits = DiffAnnotationCorrelator.correlate(hunks: [h], annotations: [ann])
        XCTAssertTrue(hits.isEmpty)
    }

    func testMultipleAnnotationsOnSameLineBothRecorded() {
        let h = sampleHunk()
        let a1 = DiffAnnotation(path: h.filePath, lineStart: 11, lineEnd: 11,
                                severity: .info, body: "one")
        let a2 = DiffAnnotation(path: h.filePath, lineStart: 11, lineEnd: 11,
                                severity: .blocker, body: "two")
        let hits = DiffAnnotationCorrelator.correlate(hunks: [h], annotations: [a1, a2])
        let bodies = Set((hits[h.filePath] ?? []).map(\.annotation.body))
        XCTAssertEqual(bodies, ["one", "two"])
    }
}
