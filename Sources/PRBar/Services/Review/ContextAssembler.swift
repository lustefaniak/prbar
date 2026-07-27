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
        workdir: URL,
        baseSha: String = "",
        customSystemPrompt: String? = nil,
        replaceBaseSystemPrompt: Bool = false,
        priorReviews: [PriorReview] = [],
        riskBrief: RiskBrief? = nil
    ) throws -> PromptBundle {
        let language = subdiff.dominantLanguage
        let basePrompt = try PromptLibrary.systemPrompt(for: language)
        let systemPrompt: String
        if let custom = customSystemPrompt, !custom.isEmpty {
            if replaceBaseSystemPrompt {
                systemPrompt = custom
            } else {
                systemPrompt = basePrompt + "\n\n" + custom
            }
        } else {
            systemPrompt = basePrompt
        }
        let userPrompt = buildUserPrompt(
            pr: pr,
            subdiff: subdiff,
            diffText: diffText,
            existingComments: existingComments,
            ciFailures: ciFailures,
            toolMode: toolMode,
            baseSha: baseSha,
            priorReviews: priorReviews,
            riskBrief: riskBrief
        )
        let subpathTag = subdiff.subpath.isEmpty ? "root" : subdiff.subpath
        return PromptBundle(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            workdir: workdir,
            prNodeId: pr.nodeId,
            subpath: subdiff.subpath,
            sessionLabel: "prbar: \(pr.nameWithOwner)#\(pr.number) (\(subpathTag))",
            baseSha: baseSha
        )
    }

    // MARK: - prompt assembly

    static func buildUserPrompt(
        pr: InboxPR,
        subdiff: Subdiff,
        diffText: String,
        existingComments: [ExistingReviewComment],
        ciFailures: [CIFailureLog],
        toolMode: ToolMode,
        baseSha: String = "",
        priorReviews: [PriorReview] = [],
        riskBrief: RiskBrief? = nil
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
        if !priorReviews.isEmpty {
            out += priorReviewsSection(priorReviews, currentSha: pr.headSha)
            out += "\n"
        }
        out += subfolderSection(subdiff: subdiff, toolMode: toolMode)
        out += "\n"
        // The brief carries every path with its +/- counts, so it *replaces*
        // the plain file list rather than being appended to it — rendering
        // both duplicated the whole file table for no added information. On a
        // generated-heavy PR the brief is the cheaper of the two, since it
        // collapses lockfiles and docs into one comma-separated line instead
        // of a bullet each.
        let brief = riskBrief.flatMap { $0.isEmpty ? nil : $0 }
        if let brief {
            out += riskBriefSection(brief)
        } else {
            out += filesChangedSection(subdiff: subdiff)
        }
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
        if toolMode == .sandboxed {
            out += exploreSection(baseSha: baseSha, subdiff: subdiff, hasRiskBrief: brief != nil)
        } else {
            out += diffSection(diffText)
        }
        return out
    }

    /// Above this many bytes of changed-line content in a single subreview,
    /// the explore prompt switches from "diff it all in one command" to
    /// "triage from the file list, pull per-file diffs for what matters".
    /// A single `git diff <base> HEAD` on a large change dumps the whole
    /// blob into context in one tool call — the worst case for token spend
    /// and the cost cap. For small changes one diff is cheaper than several
    /// scoped calls, so we only nudge file-list-first when it pays off.
    static let largeDiffThresholdBytes = 30_000

    /// Approximate byte size of a subdiff's changed-line content. Sums the
    /// content of every diff line across the subdiff's hunks — a stand-in
    /// for how big the `git diff` output the agent would pull is.
    static func subdiffContentBytes(_ subdiff: Subdiff) -> Int {
        var total = 0
        for h in subdiff.hunks {
            for line in h.lines {
                total += line.content.utf8.count + 1
            }
        }
        return total
    }

    /// Replaces the inline diff in `.sandboxed` mode. The PR head is
    /// checked out in the worktree (cwd) and the agent has git + read
    /// tools, so it inspects the change itself rather than reading a
    /// multi-thousand-line blob from the prompt. For large changes the
    /// guidance leads with file-list triage instead of a full diff so the
    /// agent's spend scales with attention, not diff size.
    private static func exploreSection(baseSha: String, subdiff: Subdiff, hasRiskBrief: Bool) -> String {
        let subpath = subdiff.subpath
        let scope = subpath.isEmpty ? "" : " -- ."
        var s = "## Reviewing the change\n\n"
        s += "The full repo at the PR head is checked out. Your working directory is "
        s += subpath.isEmpty ? "the repo root" : "the `\(subpath)` subfolder"
        if !subpath.isEmpty {
            s += "; the rest of the repo is on disk above it — read files elsewhere "
            s += "in the tree with `git show HEAD:<repo-relative-path>` or by reading up from the root"
        }
        s += ". Inspect the change with git:\n\n"

        guard !baseSha.isEmpty else {
            s += "- Change: `git diff HEAD~1 HEAD` (base SHA was unavailable)\n"
            s += "- Read or grep any file at head directly for surrounding context.\n"
            s += "- There is no network access and nothing to fix — review only; everything you need is local.\n\n"
            s += "The changed files are listed above; review only the PR's changes.\n"
            return s
        }

        let isLarge = subdiffContentBytes(subdiff) > largeDiffThresholdBytes
        if isLarge {
            s += "This is a **large change** (\(subdiff.filePaths.count) files). "
            s += "**Do not** run a single `git diff` over everything — that floods your context and burns the budget. Instead:\n\n"
            if hasRiskBrief {
                s += "- Work down the **reading order** above. Diff the top entries, skim or skip what it marks generated or docs, and stop once you can judge the change.\n"
            } else {
                s += "- Start from the **Files changed** list above. Pick the highest-risk files first (logic, security, concurrency, data handling) and skim trivial ones (generated code, lockfiles, docs).\n"
            }
            s += "- Diff one file at a time: `git diff \(baseSha) HEAD -- <path>`. Base version of a file: `git show \(baseSha):<path>`.\n"
            s += "- Read or grep only the surrounding code you need to judge a specific change.\n"
            s += "- Emit your verdict as soon as you can judge the change — you do not need to open every file. If the important files are clean, that is an approve.\n"
        } else {
            s += "- Full change: `git diff \(baseSha) HEAD\(scope)`\n"
            s += "- One file: `git diff \(baseSha) HEAD -- <path>`; the base version of a file is `git show \(baseSha):<path>`\n"
            s += "- Read or grep any file at head directly for surrounding context.\n"
        }
        s += "- There is no network access and nothing to fix — review only; everything you need is local.\n\n"
        s += "The changed files are listed above; review only the PR's changes.\n"
        return s
    }

    /// Render the chain of internal review drafts the user accumulated
    /// without posting any of them. The framing is critical: the PR
    /// author has seen *none* of these — they were drafted locally as
    /// the head moved. The model must produce one final consolidated
    /// review for the PR's current state, not a delta against a
    /// non-existent earlier comment.
    private static func priorReviewsSection(_ priors: [PriorReview], currentSha: String) -> String {
        let newShort = String(currentSha.prefix(7))
        var s = "## Earlier internal review drafts (NOT posted to GitHub)\n\n"
        s += "The PR has moved through \(priors.count) earlier commit\(priors.count == 1 ? "" : "s") "
        s += "that you previously triaged. **None of those drafts were posted** — the PR author "
        s += "has not seen any of them. Treat them as your own private notes.\n\n"
        s += "Your task now is to produce **one consolidated final review** for the PR at its current "
        s += "head `\(newShort)`. Do **not** phrase findings as updates on a previous comment "
        s += "(\"as I noted earlier\", \"this addresses my prior concern\") — from the author's "
        s += "perspective there is no prior comment. State the current state of the PR plainly. "
        s += "Use the drafts only as a memory aid: issues that were genuinely fixed by later commits "
        s += "should be omitted; issues that persist should be raised fresh in your final review.\n\n"
        for (idx, prior) in priors.enumerated() {
            let shaShort = String(prior.headSha.prefix(7))
            s += "### Draft \(idx + 1) — commit `\(shaShort)`\n\n"
            s += "- **Verdict**: `\(prior.aggregated.verdict.rawValue)` "
            s += "(confidence \(String(format: "%.0f%%", prior.aggregated.confidence * 100)))\n"
            let summary = prior.aggregated.summaryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty {
                s += "- **Summary**:\n\n"
                for line in summary.split(separator: "\n", omittingEmptySubsequences: false) {
                    s += "  > \(line)\n"
                }
            }
            let blockers = prior.aggregated.annotations.filter { $0.severity.isBlocking }
            if !blockers.isEmpty {
                s += "\n- **Blocking annotations flagged then** (re-check whether each still applies):\n"
                for ann in blockers.prefix(10) {
                    let title = ann.displayTitle.replacingOccurrences(of: "\n", with: " ")
                    s += "  - `\(ann.path):\(ann.lineStart)` — \(title)\n"
                }
            }
            s += "\n"
        }
        return s
    }

    private static func toolModeIntro(_ mode: ToolMode) -> String {
        switch mode {
        case .sandboxed:
            return """
            You are reviewing a full checkout of this PR's head commit, with \
            read-only shell access (git, grep, cat). The entire repo at this \
            commit is present on disk — read any referenced file (sibling \
            definitions, imported types, configs) directly with \
            Read/Grep/cat. Inspect the change with `git diff` (commands \
            below). **Everything you need is inside \
            the repo checkout — stay within it. Never use absolute paths to \
            reach outside the checkout, and never run `find /` or otherwise \
            search the wider filesystem.** The environment is OS-sandboxed: \
            read-only, no network. **Never attempt to fix the PR.** If the \
            change is too opaque to judge after a few lookups, return \
            verdict "abstain".
            """
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
            if toolMode == .minimal || toolMode == .sandboxed {
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

    /// Cap on ranked lines. The plain file list this replaces was uncapped,
    /// so keep it generous — the cap exists to bound a pathological
    /// several-hundred-file PR, not to truncate ordinary ones.
    static let riskBriefMaxRows = 40

    /// Renders `RiskBrief` as the subreview's file list, in reading order.
    ///
    /// The framing paragraph is the load-bearing part. Every entry is a
    /// mechanical observation ("this file is hot", "no test changed"), and a
    /// model handed a ranked list under a risk-flavoured heading will reach
    /// for it as evidence and publish `warning: no test coverage` on all six
    /// files. The publication bar in the system prompt decides whether
    /// anything gets *said*; this section only decides what gets *read*.
    private static func riskBriefSection(_ brief: RiskBrief) -> String {
        var s = "## Files changed, in suggested reading order\n\n"
        s += "Ordered by a mechanical pre-scan: diff size, whether a paired test "
        s += "changed, recent commit history, sensitive paths. It is a **reading "
        s += "order, not a finding** — no entry clears the publication bar on its "
        s += "own, and \"no test file changed\" is not a defect unless you can name "
        s += "the regression it lets through. Judge only the code you actually read.\n\n"

        let priority = brief.priorityRows.prefix(riskBriefMaxRows)
        if priority.isEmpty {
            s += "_(no hand-written files in this subreview)_\n"
        } else {
            for (idx, row) in priority.enumerated() {
                s += "\(idx + 1). `\(row.path)` (+\(row.addedLines) / -\(row.removedLines))"
                if !row.reasons.isEmpty {
                    s += " — \(row.reasons.joined(separator: "; "))"
                }
                s += "\n"
            }
            let overflow = brief.priorityRows.count - priority.count
            if overflow > 0 {
                s += "\(priority.count + 1). … and \(overflow) more, lower-ranked "
                s += "(`git diff --stat` for the full list)\n"
            }
        }

        // One line for the whole low-signal group rather than a bullet each:
        // a lockfile-heavy PR would otherwise spend more prompt on files
        // nobody should read than on the ones they should.
        let lowSignal = brief.lowSignalRows
        if !lowSignal.isEmpty {
            let names = lowSignal.prefix(12).map { "`\($0.path)`" }.joined(separator: ", ")
            let more = lowSignal.count > 12 ? ", … and \(lowSignal.count - 12) more" : ""
            s += "\nGenerated, vendored, or docs — skim or skip: \(names)\(more)\n"
        }

        if brief.changesSourceWithoutAnyTest {
            s += "\nThis subreview changes source files and no test files.\n"
        }
        if let churn = brief.churnSummary {
            s += "\nCommit-history window observed: \(churn).\n"
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
