import Foundation

/// One sub-section of a PR's diff, scoped to a single monorepo subfolder.
/// For non-monorepo (or single-root) PRs there's exactly one Subdiff with
/// `subpath = ""` covering the whole diff.
struct Subdiff: Sendable, Hashable {
    /// Repo-relative path to the subfolder this slice belongs to. Empty
    /// string ("") means "review at the repo root" — used when the
    /// `MonorepoConfig` either doesn't apply or routes unmatched hunks
    /// through `unmatchedStrategy = .reviewAtRoot`.
    let subpath: String

    /// Hunks in this slice, with their original repo-relative file paths
    /// preserved (e.g. `kernel-billing/audit/log.go`, not `audit/log.go`).
    /// The ContextAssembler may rewrite to subpath-relative when feeding
    /// claude, but the Subdiff itself uses repo-relative for clarity.
    let hunks: [Hunk]

    /// Distinct file paths touched by this subdiff. Convenience for prompt
    /// assembly + UI summaries.
    var filePaths: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for h in hunks {
            if seen.insert(h.filePath).inserted {
                ordered.append(h.filePath)
            }
        }
        return ordered
    }

    /// Dominant language detected by majority file extension. Used to pick
    /// a per-language prompt override.
    var dominantLanguage: Language {
        var tally: [Language: Int] = [:]
        for path in filePaths {
            let ext = (path as NSString).pathExtension
            tally[Language.from(fileExtension: ext), default: 0] += 1
        }
        // Pick highest, breaking ties by .swift > .typescript > .go > .unknown
        // (just to be deterministic — order doesn't otherwise matter).
        return tally
            .max(by: { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return lhs.key.rawValue < rhs.key.rawValue
            })?.key ?? .unknown
    }

    /// Human-friendly tag for the subreview, e.g. "kernel-billing" or
    /// "(repo root)" when subpath is empty.
    var displayTitle: String {
        subpath.isEmpty ? "(repo root)" : subpath
    }
}
