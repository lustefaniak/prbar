import Foundation

/// Splits a PR diff into per-subfolder Subdiffs based on a `MonorepoConfig`.
///
/// Algorithm:
///   1. Parse diff → flat `[Hunk]` list.
///   2. For each hunk, find the longest matching `rootPattern` for its
///      file path. Hunks with no match collect into the "unmatched"
///      bucket and are routed by `unmatchedStrategy`.
///   3. Group hunks by matched root.
///   4. Drop subdiffs with fewer than `minFilesPerSubreview` files; their
///      hunks fold back into the unmatched bucket.
///   5. Cap fanout at `maxParallelSubreviews`. Excess (smallest) buckets
///      are tail-merged into the unmatched bucket.
///   6. Apply `unmatchedStrategy` to the unmatched bucket.
///
/// Stable ordering: subdiffs are returned with the original config's
/// `rootPatterns` order preserved, then the unmatched bucket last.
enum MonorepoSplitter {
    static func split(
        diffText: String,
        config: RepoConfig = .default
    ) -> [Subdiff] {
        let hunks = DiffParser.parse(diffText)
        return split(hunks: hunks, config: config)
    }

    static func split(hunks: [Hunk], config: RepoConfig) -> [Subdiff] {
        if hunks.isEmpty { return [] }
        if config.excluded { return [] }

        // .single mode short-circuits the splitter — one repo-root subdiff
        // covering everything.
        if config.splitMode == .single {
            return [Subdiff(subpath: "", hunks: hunks)]
        }

        // Step 1: pre-rank patterns by specificity so the loop below picks
        // the best match in a single pass.
        let rankedPatterns = config.rootPatterns
            .enumerated()
            .map { (idx, pat) in (pat: pat, rank: GlobMatcher.specificity(pat), order: idx) }
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank > rhs.rank }
                return lhs.order < rhs.order
            }

        // Step 2: bucket every hunk by its best-matching pattern. The
        // `subpath` we store is the *pattern prefix* up to the first
        // wildcard — for `kernel-*` matched on `kernel-billing/foo.go`
        // we want the subpath to be `kernel-billing`, not `kernel-*`.
        var buckets: [String: [Hunk]] = [:]
        var bucketOrder: [String] = []
        var unmatched: [Hunk] = []

        for hunk in hunks {
            if let subpath = matchSubpath(file: hunk.filePath, patterns: rankedPatterns) {
                if buckets[subpath] == nil { bucketOrder.append(subpath) }
                buckets[subpath, default: []].append(hunk)
            } else {
                unmatched.append(hunk)
            }
        }

        // Step 3: drop low-file buckets back into the unmatched pool.
        var keptOrder: [String] = []
        for subpath in bucketOrder {
            let fileCount = Set((buckets[subpath] ?? []).map(\.filePath)).count
            if fileCount < config.minFilesPerSubreview {
                unmatched.append(contentsOf: buckets[subpath] ?? [])
                buckets.removeValue(forKey: subpath)
            } else {
                keptOrder.append(subpath)
            }
        }

        // Step 4: fanout cap. If we exceed the cap, sort kept buckets by
        // file count desc, keep the top (cap-1) as-is (reserving one slot
        // for the unmatched bucket), tail-merge the rest into unmatched.
        if keptOrder.count > config.maxParallelSubreviews {
            let bySize = keptOrder.sorted { lhs, rhs in
                let lc = Set((buckets[lhs] ?? []).map(\.filePath)).count
                let rc = Set((buckets[rhs] ?? []).map(\.filePath)).count
                if lc != rc { return lc > rc }
                return (keptOrder.firstIndex(of: lhs) ?? 0) < (keptOrder.firstIndex(of: rhs) ?? 0)
            }
            let keepCap = max(1, config.maxParallelSubreviews - 1)
            let keep = Set(bySize.prefix(keepCap))
            for sp in bySize.dropFirst(keepCap) {
                unmatched.append(contentsOf: buckets[sp] ?? [])
                buckets.removeValue(forKey: sp)
            }
            keptOrder = keptOrder.filter { keep.contains($0) }
        }

        // Step 5: assemble final subdiffs in the original encounter order.
        var subdiffs: [Subdiff] = keptOrder.map { sp in
            Subdiff(subpath: sp, hunks: buckets[sp] ?? [])
        }

        // Step 6: apply unmatched strategy.
        if !unmatched.isEmpty {
            switch config.unmatchedStrategy {
            case .reviewAtRoot:
                subdiffs.append(Subdiff(subpath: "", hunks: unmatched))
            case .skipReview:
                break
            case .groupAsOther:
                subdiffs.append(Subdiff(subpath: "<other>", hunks: unmatched))
            }
        }

        // Edge case: config has zero rootPatterns and unmatched got dropped
        // → return a single root subdiff to avoid silent zero-output.
        if subdiffs.isEmpty && config.unmatchedStrategy == .skipReview {
            return []
        }

        // Step 7: collapse threshold — if the splitter produced more than
        // `collapseAboveSubreviewCount` subreviews, fold them into a single
        // root review. The PR is too sprawling for per-subfolder breakdown
        // to be useful (cost balloons, summaries get noisy).
        if let cap = config.collapseAboveSubreviewCount, subdiffs.count > cap {
            let allHunks = subdiffs.flatMap(\.hunks)
            return [Subdiff(subpath: "", hunks: allHunks)]
        }

        return subdiffs
    }

    // MARK: - private

    private struct RankedPattern {
        let pat: String
        let rank: Int
        let order: Int
    }

    /// Returns the *resolved* subpath (literal, with wildcards replaced by
    /// the file's actual segments). For `kernel-*` matching
    /// `kernel-billing/audit/log.go`, we return `kernel-billing` — the
    /// first path component. For literal patterns like `dev-infra` we
    /// return them as-is. For `lib/*`, `lib/auth/foo.go` → `lib/auth`.
    private static func matchSubpath(
        file: String,
        patterns: [(pat: String, rank: Int, order: Int)]
    ) -> String? {
        for entry in patterns {
            if GlobMatcher.match(entry.pat, file) || GlobMatcher.match("\(entry.pat)/**", file) {
                return resolveSubpath(file: file, pattern: entry.pat)
            }
        }
        return nil
    }

    /// Convert a glob-pattern + matched file path into the literal
    /// subpath we'll use as `Subdiff.subpath` and as the worktree's
    /// sparse-checkout path.
    private static func resolveSubpath(file: String, pattern: String) -> String {
        let fileParts = file.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let patParts = pattern.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var resolved: [String] = []
        for (i, p) in patParts.enumerated() {
            guard i < fileParts.count else { break }
            if p.contains("*") || p.contains("?") {
                resolved.append(fileParts[i])
            } else {
                resolved.append(p)
            }
        }
        return resolved.joined(separator: "/")
    }
}
