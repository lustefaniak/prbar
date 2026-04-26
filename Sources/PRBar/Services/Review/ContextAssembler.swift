import Foundation

/// Existing review comment fetched off the PR. Used to tell the AI "don't
/// repeat what others have already said". For Phase 2 MVP callers pass [];
/// Phase 2+ will plumb these through from the GraphQL response.
struct ExistingReviewComment: Sendable, Hashable {
    let author: String
    let body: String
    let isReview: Bool   // true for top-level review summary, false for inline
}

/// Tail of a failed CI job's logs, for the prompt's "CI failures" section.
/// Phase 2 MVP ships without these — callers pass []. Phase 2+ will fetch
/// via `gh run view --log-failed`.
struct CIFailureLog: Sendable, Hashable {
    let jobName: String
    let logTail: String       // last ~200 lines
}

enum ContextAssembler {
    /// Build the prompt bundle for one subreview. Pure function — all
    /// inputs explicit, no I/O.
    static func assemble(
        pr: InboxPR,
        subdiff: Subdiff,
        diffText: String,
        existingComments: [ExistingReviewComment] = [],
        ciFailures: [CIFailureLog] = [],
        toolMode: ToolMode,
        workdir: URL
    ) throws -> PromptBundle {
        let language = subdiff.dominantLanguage
        let systemPrompt = try PromptLibrary.systemPrompt(for: language)
        let userPrompt = buildUserPrompt(
            pr: pr,
            subdiff: subdiff,
            diffText: diffText,
            existingComments: existingComments,
            ciFailures: ciFailures,
            toolMode: toolMode
        )
        return PromptBundle(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            workdir: workdir,
            prNodeId: pr.nodeId,
            subpath: subdiff.subpath
        )
    }

    // MARK: - prompt assembly

    static func buildUserPrompt(
        pr: InboxPR,
        subdiff: Subdiff,
        diffText: String,
        existingComments: [ExistingReviewComment],
        ciFailures: [CIFailureLog],
        toolMode: ToolMode
    ) -> String {
        var out = ""
        out += "# Pull Request Review\n\n"
        out += toolModeIntro(toolMode)
        out += "\n\n"
        out += prSection(pr: pr)
        out += "\n"
        if !pr.body.isEmpty {
            out += "## PR description\n\n"
            out += pr.body.trimmingCharacters(in: .whitespacesAndNewlines)
            out += "\n\n"
        }
        out += subfolderSection(subdiff: subdiff, toolMode: toolMode)
        out += "\n"
        out += filesChangedSection(subdiff: subdiff)
        out += "\n"
        if !existingComments.isEmpty {
            out += existingCommentsSection(existingComments)
            out += "\n"
        }
        out += ciStatusSection(checks: pr.allCheckSummaries)
        out += "\n"
        if !ciFailures.isEmpty {
            out += ciFailuresSection(ciFailures)
            out += "\n"
        }
        out += diffSection(diffText)
        return out
    }

    private static func toolModeIntro(_ mode: ToolMode) -> String {
        switch mode {
        case .minimal:
            return """
            You have read-only access to files under `./` (the subfolder \
            named below), plus WebFetch/WebSearch for verifying external \
            claims. Use tools sparingly — the diff and brief below should \
            be enough for most reviews. Hard cap: ~10 tool calls per review. \
            **Never attempt to fix the PR.** If after a couple of targeted \
            lookups the diff is still too opaque, return verdict "abstain".
            """
        case .none:
            return """
            You have **no tool access**. Analyze only what is shown below \
            and return a structured verdict. **Never attempt to fix the PR.** \
            If the diff is too small or opaque to judge, return verdict \
            "abstain".
            """
        }
    }

    private static func prSection(pr: InboxPR) -> String {
        var s = "## PR\n\n"
        s += "- **Repo**: \(pr.nameWithOwner)\n"
        s += "- **Number**: #\(pr.number)\n"
        s += "- **Title**: \(pr.title)\n"
        s += "- **Author**: @\(pr.author)\n"
        s += "- **Base → Head**: `\(pr.baseRef)` → `\(pr.headRef)`\n"
        s += "- **Size**: +\(pr.totalAdditions) / -\(pr.totalDeletions) across \(pr.changedFiles) file\(pr.changedFiles == 1 ? "" : "s")\n"
        if pr.isDraft {
            s += "- **Status**: draft\n"
        }
        return s
    }

    private static func subfolderSection(subdiff: Subdiff, toolMode: ToolMode) -> String {
        var s = "## Subfolder under review\n\n"
        if subdiff.subpath.isEmpty {
            s += "Repo root."
        } else {
            s += "`\(subdiff.subpath)`"
            if toolMode == .minimal {
                s += " (cwd is set here — `./CLAUDE.md`, `./.mcp.json`, and walk-up configs apply)"
            }
        }
        s += "\n"
        return s
    }

    private static func filesChangedSection(subdiff: Subdiff) -> String {
        var s = "## Files changed in this subreview\n\n"
        if subdiff.filePaths.isEmpty {
            s += "_(no files)_\n"
            return s
        }
        // Compute per-file +/- counts from the hunks.
        var addsByFile: [String: Int] = [:]
        var delsByFile: [String: Int] = [:]
        for h in subdiff.hunks {
            for line in h.lines {
                switch line {
                case .added:   addsByFile[h.filePath, default: 0] += 1
                case .removed: delsByFile[h.filePath, default: 0] += 1
                case .context: break
                }
            }
        }
        for path in subdiff.filePaths {
            let adds = addsByFile[path] ?? 0
            let dels = delsByFile[path] ?? 0
            s += "- `\(path)` (+\(adds) / -\(dels))\n"
        }
        return s
    }

    private static func existingCommentsSection(_ comments: [ExistingReviewComment]) -> String {
        var s = "## Existing review comments (do not repeat)\n\n"
        for c in comments.prefix(20) {
            let body = c.body.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            let truncated = body.count > 200 ? String(body.prefix(200)) + "…" : body
            s += "- @\(c.author): \"\(truncated)\"\n"
        }
        return s
    }

    private static func ciStatusSection(checks: [CheckSummary]) -> String {
        var s = "## CI status\n\n"
        if checks.isEmpty {
            s += "_(no checks reported)_\n"
            return s
        }
        for check in checks.prefix(20) {
            let state = check.conclusion ?? check.status ?? "UNKNOWN"
            let icon: String
            switch state {
            case "SUCCESS":           icon = "✓"
            case "FAILURE", "ERROR":  icon = "✗"
            case "PENDING", "QUEUED", "IN_PROGRESS", "EXPECTED": icon = "⏳"
            default:                  icon = "•"
            }
            s += "- \(icon) `\(check.name)` (\(state))\n"
        }
        if checks.count > 20 {
            s += "- … and \(checks.count - 20) more\n"
        }
        return s
    }

    private static func ciFailuresSection(_ failures: [CIFailureLog]) -> String {
        var s = "## CI failures (last lines per failed job)\n\n"
        for f in failures {
            s += "### `\(f.jobName)`\n\n"
            s += "```\n"
            s += f.logTail
            if !f.logTail.hasSuffix("\n") { s += "\n" }
            s += "```\n\n"
        }
        return s
    }

    private static func diffSection(_ diffText: String) -> String {
        var s = "## Diff\n\n"
        s += "```diff\n"
        s += diffText
        if !diffText.hasSuffix("\n") { s += "\n" }
        s += "```\n"
        return s
    }
}
