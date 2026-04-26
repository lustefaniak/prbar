import XCTest
@testable import PRBar

final class SubdiffTests: XCTestCase {
    func testFilePathsPreserveOrderAndDedupe() {
        let s = Subdiff(
            subpath: "kernel-billing",
            hunks: [
                hunk(path: "kernel-billing/api/handler.go"),
                hunk(path: "kernel-billing/audit/log.go"),
                hunk(path: "kernel-billing/api/handler.go"),    // dup
            ]
        )
        XCTAssertEqual(s.filePaths, [
            "kernel-billing/api/handler.go",
            "kernel-billing/audit/log.go",
        ])
    }

    func testDominantLanguageDetectsGo() {
        let s = Subdiff(
            subpath: "kernel-billing",
            hunks: [
                hunk(path: "kernel-billing/api/handler.go"),
                hunk(path: "kernel-billing/audit/log.go"),
                hunk(path: "kernel-billing/README.md"),
            ]
        )
        XCTAssertEqual(s.dominantLanguage, .go)
    }

    func testDominantLanguageDetectsTypeScriptFromMixedJSExtensions() {
        let s = Subdiff(
            subpath: "fe-app",
            hunks: [
                hunk(path: "fe-app/src/Button.tsx"),
                hunk(path: "fe-app/src/utils.ts"),
                hunk(path: "fe-app/src/legacy.js"),
            ]
        )
        XCTAssertEqual(s.dominantLanguage, .typescript)
    }

    func testDominantLanguageUnknownForUnrecognizedExtensions() {
        let s = Subdiff(
            subpath: "config",
            hunks: [
                hunk(path: "config/Pulumi.yaml"),
                hunk(path: "config/values.json"),
            ]
        )
        XCTAssertEqual(s.dominantLanguage, .unknown)
    }

    func testDisplayTitleEmptyMeansRepoRoot() {
        XCTAssertEqual(Subdiff(subpath: "", hunks: []).displayTitle, "(repo root)")
        XCTAssertEqual(Subdiff(subpath: "lib/auth", hunks: []).displayTitle, "lib/auth")
    }

    private func hunk(path: String) -> Hunk {
        Hunk(filePath: path, oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, lines: [])
    }
}
