import Foundation

/// Splits a PR diff into per-subfolder Subdiffs. Phase 2 ships a trivial
/// pass-through: one Subdiff covering the whole PR with `subpath = ""`.
/// Phase 4 will add real per-subpath grouping driven by `MonorepoConfig`
/// (rootPatterns, unmatchedStrategy, fanout cap).
enum MonorepoSplitter {
    static func split(diffText: String) -> [Subdiff] {
        let hunks = DiffParser.parse(diffText)
        if hunks.isEmpty {
            return []
        }
        return [Subdiff(subpath: "", hunks: hunks)]
    }
}
