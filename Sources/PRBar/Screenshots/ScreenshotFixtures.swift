import Foundation

/// Deterministic, generic-looking fixture data for the marketing
/// screenshot path. NEVER include real customer / workspace identifiers
/// — these payloads ship as PNGs committed under `docs/screenshots/`
/// and rendered inline by the project README.
///
/// Three PRs cover the interesting visual states:
///   - `readyToMerge`: clean CI, approved, mergeable → green primary action
///   - `inReview`:     review-requested, AI verdict = approve with two
///                     suggestion annotations → AI panel + diff overlay
///   - `ciFailing`:    review-requested, CI failure → red badge + failure
///                     log section
enum ScreenshotFixtures {
    static let prReadyToMerge = InboxPR(
        nodeId: "PR_demo_ready",
        owner: "acme",
        repo: "platform",
        number: 4218,
        title: "feat(api): add cursor-based pagination to /v2/orders",
        body: """
        ## Summary

        Replaces offset pagination with **opaque cursors** for the orders
        endpoint. Cursors encode `(created_at, id)` as a base64 blob and are
        opaque to clients.

        - Migration is backwards-compatible: `?page=N` still works for one
          release, then will be removed in v3.
        - Cursor TTL is 24h; expired cursors return `409` with a hint to
          restart the iteration.

        Refs: PLATFORM-2891
        """,
        url: URL(string: "https://github.com/acme/platform/pull/4218")!,
        author: "rachel.kim",
        headRef: "rachel-cursor-pagination",
        baseRef: "main",
        headSha: "a4d7c1f9b2e3",
        isDraft: false,
        role: .authored,
        mergeable: "MERGEABLE",
        mergeStateStatus: "CLEAN",
        reviewDecision: "APPROVED",
        checkRollupState: "SUCCESS",
        totalAdditions: 412,
        totalDeletions: 88,
        changedFiles: 14,
        hasAutoMerge: false,
        autoMergeEnabledBy: nil,
        allCheckSummaries: [
            CheckSummary(typename: "CheckRun", name: "build",          conclusion: "SUCCESS", status: "COMPLETED", url: nil),
            CheckSummary(typename: "CheckRun", name: "unit-tests",     conclusion: "SUCCESS", status: "COMPLETED", url: nil),
            CheckSummary(typename: "CheckRun", name: "integration",    conclusion: "SUCCESS", status: "COMPLETED", url: nil),
            CheckSummary(typename: "CheckRun", name: "lint",           conclusion: "SUCCESS", status: "COMPLETED", url: nil),
        ],
        allowedMergeMethods: [.squash, .rebase],
        autoMergeAllowed: true,
        deleteBranchOnMerge: true
    )

    static let prInReview = InboxPR(
        nodeId: "PR_demo_review",
        owner: "acme",
        repo: "platform",
        number: 4221,
        title: "refactor(billing): split InvoiceRenderer into per-format modules",
        body: """
        Breaks the 1.4k-line `InvoiceRenderer` into `PdfRenderer`,
        `HtmlRenderer`, and `CsvRenderer`, each behind a shared
        `InvoiceFormat` protocol. Pure mechanical extraction — no
        behaviour change. Tests rerun green; visual diff against last
        100 production invoices is byte-identical.
        """,
        url: URL(string: "https://github.com/acme/platform/pull/4221")!,
        author: "marcus.lee",
        headRef: "marcus-split-invoice-renderer",
        baseRef: "main",
        headSha: "8f1d92ac5e07",
        isDraft: false,
        role: .reviewRequested,
        mergeable: "MERGEABLE",
        mergeStateStatus: "BLOCKED",
        reviewDecision: "REVIEW_REQUIRED",
        checkRollupState: "SUCCESS",
        totalAdditions: 738,
        totalDeletions: 612,
        changedFiles: 22,
        hasAutoMerge: false,
        autoMergeEnabledBy: nil,
        allCheckSummaries: [
            CheckSummary(typename: "CheckRun", name: "build",        conclusion: "SUCCESS", status: "COMPLETED", url: nil),
            CheckSummary(typename: "CheckRun", name: "unit-tests",   conclusion: "SUCCESS", status: "COMPLETED", url: nil),
            CheckSummary(typename: "CheckRun", name: "integration",  conclusion: "SUCCESS", status: "COMPLETED", url: nil),
        ],
        allowedMergeMethods: [.squash, .rebase],
        autoMergeAllowed: true,
        deleteBranchOnMerge: true
    )

    static let prCiFailing = InboxPR(
        nodeId: "PR_demo_ci_failing",
        owner: "acme",
        repo: "platform",
        number: 4225,
        title: "fix(scheduler): retry on transient quorum-loss errors",
        body: """
        Retry up to 3 times with exponential backoff (250ms / 500ms /
        1s) when the scheduler sees `QUORUM_LOST` from etcd. Above that,
        bail and let the supervisor restart us — preserves at-least-once
        semantics without spinning forever.
        """,
        url: URL(string: "https://github.com/acme/platform/pull/4225")!,
        author: "priya.shah",
        headRef: "priya-scheduler-retry",
        baseRef: "main",
        headSha: "c3e0a9145bd8",
        isDraft: false,
        role: .reviewRequested,
        mergeable: "MERGEABLE",
        mergeStateStatus: "BEHIND",
        reviewDecision: "REVIEW_REQUIRED",
        checkRollupState: "FAILURE",
        totalAdditions: 96,
        totalDeletions: 12,
        changedFiles: 4,
        hasAutoMerge: false,
        autoMergeEnabledBy: nil,
        allCheckSummaries: [
            CheckSummary(typename: "CheckRun", name: "build",        conclusion: "SUCCESS", status: "COMPLETED", url: nil),
            CheckSummary(typename: "CheckRun", name: "unit-tests",   conclusion: "FAILURE", status: "COMPLETED", url: "https://example.invalid/jobs/123"),
            CheckSummary(typename: "CheckRun", name: "integration",  conclusion: "SUCCESS", status: "COMPLETED", url: nil),
            CheckSummary(typename: "CheckRun", name: "lint",         conclusion: "SUCCESS", status: "COMPLETED", url: nil),
        ],
        allowedMergeMethods: [.squash, .rebase],
        autoMergeAllowed: true,
        deleteBranchOnMerge: true
    )

    static let allPRs: [InboxPR] = [prReadyToMerge, prInReview, prCiFailing]

    /// Curated AggregatedReview for `prInReview`. Shows: approve verdict,
    /// 0.92 confidence, two suggestion annotations on different files,
    /// one summary section. Looks like a real claude/codex output.
    static let reviewForInReview: AggregatedReview = AggregatedReview(
        verdict: .approve,
        confidence: 0.92,
        summaryMarkdown: """
        Mechanical split of the renderer into per-format modules. Public
        surface (`InvoiceFormat.render(_:)`) stays identical and every
        existing call site routes through the protocol unchanged.

        - **Behaviour preserved**: the spot-checked PDF / HTML / CSV
          outputs are byte-identical to `main` against the fixture set
          in `Tests/InvoiceRendererTests`.
        - **Test coverage carries over** unchanged — same fixtures, same
          assertions, just split across the three module test targets.
        - Two minor naming nits flagged inline; not blocking.
        """,
        annotations: [
            DiffAnnotation(
                path: "billing/PdfRenderer/PdfRenderer.swift",
                lineStart: 47,
                lineEnd: 47,
                severity: .suggestion,
                title: "Consider renaming pageMargins → defaultPageMargins",
                body: "The constant is shadowed by the instance property of the same name 11 lines below. Renaming the static lets-default avoids a future reader having to scroll up to disambiguate."
            ),
            DiffAnnotation(
                path: "billing/HtmlRenderer/HtmlRenderer.swift",
                lineStart: 119,
                lineEnd: 124,
                severity: .suggestion,
                title: "Escape templating variables explicitly",
                body: "`HtmlRenderer.template(for:)` interpolates customer-provided strings without an explicit escape. The current call sites all pre-escape, but a future caller may not — wrap the interpolation site with `escapeHtml(_:)` defensively."
            ),
            DiffAnnotation(
                path: "billing/InvoiceFormat.swift",
                lineStart: 12,
                lineEnd: 18,
                severity: .info,
                title: "Protocol doc note about thread-safety",
                body: "Worth a one-line `/// Renderers are expected to be Sendable and stateless.` so future implementations don't introduce hidden state that breaks parallel batch rendering."
            ),
        ],
        costUsd: 0.078,
        toolCallCount: 14,
        toolNamesUsed: ["Read", "Grep", "Glob"],
        perSubreview: [],
        isSubscriptionAuth: true
    )

    static let allReviewStates: [String: ReviewState] = [
        prInReview.nodeId: ReviewState(
            prNodeId: prInReview.nodeId,
            providerId: .claude,
            headSha: prInReview.headSha,
            triggeredAt: Date(timeIntervalSinceNow: -180),
            status: .completed(reviewForInReview),
            costUsd: 0.078,
            priorReview: nil
        )
    ]

    /// Pick the right showcase PR for each detail-style stage.
    static func detailPR(for stage: ScreenshotMode.Stage) -> InboxPR {
        switch stage {
        case .windowDetail, .popoverDetail:
            return prInReview
        default:
            return prInReview
        }
    }
}
