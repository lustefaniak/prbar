import XCTest
import SwiftUI
import AppKit
@testable import PRBar

/// Generates marketing-quality screenshots of PRBar's UI in known
/// fixture states, and serves as a UI regression net — re-running this
/// test rewrites every PNG; `git diff docs/screenshots/` then shows
/// pixel-level changes from a refactor.
///
/// Output: `<repo>/docs/screenshots/<scenario>@2x.png`. The 2x scale
/// produces retina-resolution captures suitable for landing pages and
/// the README. Each scenario uses fully-mocked services — no `gh`, no
/// `claude`, no network.
///
/// To run only this class:
/// ```
/// xcodebuild -project PRBar.xcodeproj -scheme PRBar \
///   -destination "platform=macOS,arch=$(uname -m)" \
///   -only-testing:PRBarTests/ScreenshotTests test
/// ```
@MainActor
final class ScreenshotTests: XCTestCase {

    // MARK: - scenarios

    func test_01_inboxList() throws {
        let f = makeFixtures(scenario: .inboxBusy)
        let prs = f.poller.prs
            .filter { $0.role == .reviewRequested || $0.role == .both }
        let view = PopoverChrome {
            PRListView(
                prs: prs,
                emptyText: "No reviews requested.",
                isFetching: false, lastError: nil,
                refreshingPRs: [], mergingPRs: [],
                onRefreshPR: { _ in }, onMergePR: { _, _ in },
                onSelect: { _ in },
                screenshotMode: true
            )
        }
        try render(
            view: view.environments(f),
            size: popoverSize,
            name: "01-inbox-list"
        )
    }

    func test_02_myPRs() throws {
        let f = makeFixtures(scenario: .myPRsMixed)
        let prs = f.poller.prs
            .filter { $0.role == .authored || $0.role == .both }
        let view = PopoverChrome {
            PRListView(
                prs: prs,
                emptyText: "No PRs you authored.",
                isFetching: false, lastError: nil,
                refreshingPRs: [], mergingPRs: [],
                onRefreshPR: { _ in }, onMergePR: { _, _ in },
                onSelect: { _ in },
                screenshotMode: true
            )
        }
        try render(
            view: view.environments(f),
            size: popoverSize,
            name: "02-my-prs"
        )
    }

    func test_03_prDetailCompletedReview() throws {
        let f = makeFixtures(scenario: .detailCompleted)
        guard let pr = f.poller.prs.first(where: { $0.nodeId == "PR_DETAIL_OK" }) else {
            return XCTFail("missing fixture PR")
        }
        let view = PRDetailView(
            pr: pr, onBack: {}, onPostedAction: {}, screenshotMode: true
        )
        try render(
            view: AnyView(view.environments(f)),
            size: detailSize,
            name: "03-pr-detail-completed"
        )
    }

    func test_04_prDetailLiveProgress() throws {
        let f = makeFixtures(scenario: .detailRunning)
        guard let pr = f.poller.prs.first(where: { $0.nodeId == "PR_DETAIL_RUN" }) else {
            return XCTFail("missing fixture PR")
        }
        let view = PRDetailView(
            pr: pr, onBack: {}, onPostedAction: {}, screenshotMode: true
        )
        try render(
            view: AnyView(view.environments(f)),
            size: detailSize,
            name: "04-pr-detail-running"
        )
    }

    func test_05_prDetailRetriage() throws {
        let f = makeFixtures(scenario: .detailRetriage)
        guard let pr = f.poller.prs.first(where: { $0.nodeId == "PR_DETAIL_RETRI" }) else {
            return XCTFail("missing fixture PR")
        }
        let view = PRDetailView(
            pr: pr, onBack: {}, onPostedAction: {}, screenshotMode: true
        )
        try render(
            view: AnyView(view.environments(f)),
            size: detailSize,
            name: "05-pr-detail-retriage"
        )
    }

    // Settings screenshots are intentionally omitted: SwiftUI Form
    // controls (Toggle, TextField, Picker, Slider, Stepper, TextEditor)
    // are NSControl-backed and `ImageRenderer` captures them as the
    // yellow "image not loaded" placeholder. Capture those manually
    // via `screencapture -wo path.png` against a running app when a
    // marketing shot of the Settings panes is needed.

    // MARK: - rendering

    private let popoverSize = CGSize(
        width: PRBarPopoverSize.width,
        height: PRBarPopoverSize.height
    )

    /// Detail view contains a ScrollView; ImageRenderer renders at the
    /// proposed size, so we render extra-tall to capture all sections
    /// (CI status, AI verdict, annotations, diff, actions). Crop later
    /// in Figma if a tighter aspect ratio is needed for marketing.
    private let detailSize = CGSize(width: 720, height: 1500)

    private func render<V: View>(view: V, size: CGSize, name: String) throws {
        let renderer = ImageRenderer(content:
            view
                .frame(width: size.width, height: size.height)
                .background(Color(NSColor.windowBackgroundColor))
        )
        renderer.scale = 2.0
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)

        guard let cgImage = renderer.cgImage else {
            return XCTFail("ImageRenderer produced no cgImage for \(name)")
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        bitmap.size = size
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("failed to encode PNG for \(name)")
        }

        let outDir = Self.screenshotsDirectory()
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let outURL = outDir.appendingPathComponent("\(name)@2x.png")
        try pngData.write(to: outURL, options: .atomic)
        XCTContext.runActivity(named: "Screenshot: \(name)") { activity in
            let attachment = XCTAttachment(contentsOfFile: outURL)
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        print("Screenshot written: \(outURL.path)")
    }

    /// `<repo>/docs/screenshots/`. Resolves from this source file's path
    /// so it lands in the working tree, not the DerivedData test bundle.
    static func screenshotsDirectory() -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        // Tests/PRBarTests/ScreenshotTests.swift → repo root is two up.
        let repoRoot = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot.appendingPathComponent("docs/screenshots", isDirectory: true)
    }
}

// MARK: - fixtures

@MainActor
struct ScreenshotFixtures {
    let poller: PRPoller
    let notifier: Notifier
    let queue: ReviewQueueWorker
    let diffStore: DiffStore
    let repoConfigs: RepoConfigStore
    let readiness: ReadinessCoordinator
}

extension View {
    @MainActor
    func environments(_ f: ScreenshotFixtures) -> some View {
        self
            .environment(f.poller)
            .environment(f.notifier)
            .environment(f.queue)
            .environment(f.diffStore)
            .environment(f.repoConfigs)
            .environment(f.readiness)
    }
}

@MainActor
private enum Scenario {
    case inboxBusy
    case myPRsMixed
    case detailCompleted
    case detailRunning
    case detailRetriage
    case settingsRepos
}

@MainActor
private func makeFixtures(scenario: Scenario) -> ScreenshotFixtures {
    let poller = PRPoller(fetcher: { [] })
    let notifier = Notifier(deliverer: NoopDeliverer())
    let queue = ReviewQueueWorker(diffFetcher: { _, _, _ in "" })
    let diffStore = DiffStore(diffFetcher: { _, _, _ in "" })
    // Use a temp file so we don't trample the user's real config.
    let tmpConfigURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("prbar-screenshot-configs-\(UUID().uuidString).json")
    let repoConfigs = RepoConfigStore(fileURL: tmpConfigURL)
    let readiness = ReadinessCoordinator(notifier: notifier)

    switch scenario {
    case .inboxBusy:
        let prs = inboxBusyPRs()
        poller._setPRsForScreenshot(prs)
        // Two have completed AI verdicts visible in the row, one queued,
        // one running.
        var reviews: [String: ReviewState] = [:]
        reviews["PR_RUN_FE"] = .init(
            prNodeId: "PR_RUN_FE", headSha: "abc1",
            triggeredAt: Date(), status: .running, costUsd: 0
        )
        reviews["PR_OK_API"] = .init(
            prNodeId: "PR_OK_API", headSha: "abc2",
            triggeredAt: Date(),
            status: .completed(makeAggReview(.approve, summary: "LGTM. Idempotency OK; existing tests cover it.")),
            costUsd: 0.04
        )
        reviews["PR_CHG_BIL"] = .init(
            prNodeId: "PR_CHG_BIL", headSha: "abc3",
            triggeredAt: Date(),
            status: .completed(makeAggReview(.requestChanges,
                summary: "Goroutine on err path leaks the workspace context.")),
            costUsd: 0.07
        )
        queue._setReviewsForScreenshot(reviews)

    case .myPRsMixed:
        poller._setPRsForScreenshot(myPRsMixedPRs())

    case .detailCompleted:
        let pr = makePR(
            nodeId: "PR_DETAIL_OK",
            owner: "acme", repo: "platform", number: 1842,
            title: "lib/audit: emit redaction events for PII fields",
            author: "morgan",
            role: .reviewRequested,
            mergeStateStatus: "BLOCKED",
            reviewDecision: "REVIEW_REQUIRED",
            checkRollupState: "SUCCESS",
            additions: 142, deletions: 18, files: 6,
            checks: [
                CheckSummary(typename: "CheckRun", name: "CI / build",  conclusion: "SUCCESS", status: "COMPLETED", url: nil),
                CheckSummary(typename: "CheckRun", name: "CI / test",   conclusion: "SUCCESS", status: "COMPLETED", url: nil),
                CheckSummary(typename: "CheckRun", name: "CI / lint",   conclusion: "SUCCESS", status: "COMPLETED", url: nil),
            ]
        )
        poller._setPRsForScreenshot([pr])

        let agg = makeAggReview(
            .comment,
            confidence: 0.78,
            summary: """
            **Looks safe overall.** The redaction path is well-tested and the new \
            event shape mirrors existing ones. One non-blocker: the `nil`-payload \
            branch silently skips emission instead of logging — could mask a future \
            regression where the upstream stops populating fields entirely.
            """,
            annotations: [
                DiffAnnotation(
                    path: "lib/audit/emitter.go",
                    lineStart: 84, lineEnd: 86,
                    severity: .warning,
                    title: "Silent skip on nil payload",
                    body: "Consider logging at WARN when `evt.Payload == nil` so a regression in upstream propagation is visible in metrics."
                ),
                DiffAnnotation(
                    path: "lib/audit/emitter.go",
                    lineStart: 112, lineEnd: 112,
                    severity: .info,
                    title: "Field name shadows package import",
                    body: "`audit` shadows the package import name; harmless but a future maintainer might be confused."
                ),
                DiffAnnotation(
                    path: "lib/audit/emitter_test.go",
                    lineStart: 47, lineEnd: 48,
                    severity: .suggestion,
                    title: "Table test could cover empty redaction list",
                    body: "Existing tests don't exercise the `RedactedFields: nil` case, which is reachable from the public API."
                ),
            ],
            costUsd: 0.06,
            toolCallCount: 4,
            toolNamesUsed: ["Read", "Grep", "Read"]
        )
        queue._setReviewsForScreenshot([
            "PR_DETAIL_OK": .init(
                prNodeId: "PR_DETAIL_OK",
                headSha: pr.headSha,
                triggeredAt: Date(),
                status: .completed(agg),
                costUsd: 0.06
            )
        ])
        diffStore._setLoadedForScreenshot(pr: pr, hunks: emitterDiffHunks())

    case .detailRunning:
        let pr = makePR(
            nodeId: "PR_DETAIL_RUN",
            owner: "acme", repo: "platform", number: 1855,
            title: "kernel-billing: refactor invoice generation pipeline",
            author: "priya",
            role: .reviewRequested,
            mergeStateStatus: "BLOCKED",
            reviewDecision: "REVIEW_REQUIRED",
            checkRollupState: "PENDING",
            additions: 318, deletions: 207, files: 11,
            checks: [
                CheckSummary(typename: "CheckRun", name: "CI / build", conclusion: nil, status: "IN_PROGRESS", url: nil),
                CheckSummary(typename: "CheckRun", name: "CI / test",  conclusion: nil, status: "IN_PROGRESS", url: nil),
            ]
        )
        poller._setPRsForScreenshot([pr])
        queue._setReviewsForScreenshot([
            "PR_DETAIL_RUN": .init(
                prNodeId: "PR_DETAIL_RUN",
                headSha: pr.headSha,
                triggeredAt: Date(),
                status: .running,
                costUsd: 0
            )
        ])
        queue._setLiveProgressForScreenshot([
            "PR_DETAIL_RUN": ReviewProgress(
                toolCallCount: 3,
                toolNamesUsed: ["Read", "Grep", "Read"],
                costUsdSoFar: 0.024,
                lastAssistantText: "Checking how invoice rounding interacts with the new money type…"
            )
        ])
        diffStore._setLoadedForScreenshot(pr: pr, hunks: invoiceDiffHunks())

    case .detailRetriage:
        let pr = makePR(
            nodeId: "PR_DETAIL_RETRI",
            owner: "acme", repo: "platform", number: 1903,
            title: "fe-app: virtualize PR list for >500 rows",
            author: "kai",
            headSha: "newSha7",
            role: .reviewRequested,
            mergeStateStatus: "BLOCKED",
            reviewDecision: "REVIEW_REQUIRED",
            checkRollupState: "SUCCESS",
            additions: 98, deletions: 64, files: 4,
            checks: [
                CheckSummary(typename: "CheckRun", name: "CI / build", conclusion: "SUCCESS", status: "COMPLETED", url: nil),
            ]
        )
        poller._setPRsForScreenshot([pr])

        let priorAgg = makeAggReview(
            .requestChanges,
            confidence: 0.71,
            summary: "**Two blocking issues** with row recycling under fast scroll. The reusable cell pool isn't keyed on PR id so stale verdicts can flash before the new row hydrates.",
            annotations: [
                DiffAnnotation(
                    path: "fe-app/src/PRRow.tsx",
                    lineStart: 38, lineEnd: 42,
                    severity: .blocker,
                    title: "Row recycling shows stale verdict for ~1 frame",
                    body: "The cell key should include `pr.nodeId` so React forces a remount on recycle."
                ),
            ],
            costUsd: 0.05,
            toolCallCount: 2,
            toolNamesUsed: ["Read", "Read"]
        )
        let prior = PriorReview(headSha: "oldSha2", aggregated: priorAgg)
        queue._setReviewsForScreenshot([
            "PR_DETAIL_RETRI": .init(
                prNodeId: "PR_DETAIL_RETRI",
                headSha: pr.headSha,
                triggeredAt: Date(),
                status: .running,
                costUsd: 0,
                priorReview: prior
            )
        ])
        queue._setLiveProgressForScreenshot([
            "PR_DETAIL_RETRI": ReviewProgress(
                toolCallCount: 1,
                toolNamesUsed: ["Read"],
                costUsdSoFar: 0.011,
                lastAssistantText: "Verifying the cell-key fix in the new commit…"
            )
        ])
        diffStore._setLoadedForScreenshot(pr: pr, hunks: virtualListDiffHunks())

    case .settingsRepos:
        // Seed two configs so the sidebar shows "From your inbox"
        // suggestions and a real edit target.
        var cfg = RepoConfig.default
        cfg.repoGlobs = ["acme/platform"]
        cfg.rootPatterns = ["kernel-*", "lib/*", "fe-app", "api"]
        cfg.maxParallelSubreviews = 4
        cfg.collapseAboveSubreviewCount = 6
        cfg.autoApprove = AutoApproveConfig(
            enabled: true, minConfidence: 0.9,
            requireZeroBlockingAnnotations: true,
            maxAdditions: 200
        )
        cfg.notifyPolicy = .batchSettled
        repoConfigs.upsert(cfg)
        poller._setPRsForScreenshot([
            makePR(nodeId: "S1", owner: "acme", repo: "platform", number: 1, title: "x", author: "a", role: .both),
            makePR(nodeId: "S2", owner: "acme", repo: "infra",    number: 2, title: "y", author: "b", role: .reviewRequested),
        ])
    }

    return ScreenshotFixtures(
        poller: poller,
        notifier: notifier,
        queue: queue,
        diffStore: diffStore,
        repoConfigs: repoConfigs,
        readiness: readiness
    )
}

// MARK: - PR fixtures

@MainActor
private func inboxBusyPRs() -> [InboxPR] {
    [
        makePR(
            nodeId: "PR_RUN_FE",
            owner: "acme", repo: "platform", number: 1844,
            title: "fe-app: keyboard shortcuts for inbox triage",
            author: "lin",
            role: .reviewRequested,
            checkRollupState: "PENDING",
            additions: 87, deletions: 21, files: 5
        ),
        makePR(
            nodeId: "PR_OK_API",
            owner: "acme", repo: "platform", number: 1839,
            title: "api: idempotency keys for billing webhooks",
            author: "renee",
            role: .reviewRequested,
            mergeStateStatus: "BLOCKED",
            reviewDecision: "REVIEW_REQUIRED",
            checkRollupState: "SUCCESS",
            additions: 64, deletions: 8, files: 3
        ),
        makePR(
            nodeId: "PR_CHG_BIL",
            owner: "acme", repo: "platform", number: 1827,
            title: "kernel-billing: parallelize invoice fanout",
            author: "akira",
            role: .reviewRequested,
            mergeStateStatus: "BLOCKED",
            reviewDecision: "CHANGES_REQUESTED",
            checkRollupState: "FAILURE",
            additions: 220, deletions: 41, files: 8
        ),
        makePR(
            nodeId: "PR_DRAFT",
            owner: "acme", repo: "platform", number: 1816,
            title: "WIP: schema migration for tenant scoping",
            author: "sam",
            isDraft: true,
            role: .reviewRequested,
            additions: 410, deletions: 280, files: 14
        ),
    ]
}

@MainActor
private func myPRsMixedPRs() -> [InboxPR] {
    [
        makePR(
            nodeId: "M_READY",
            owner: "acme", repo: "platform", number: 1851,
            title: "lib/timefmt: replace strftime path with go-i18n formatter",
            author: "me",
            role: .authored,
            mergeStateStatus: "CLEAN",
            reviewDecision: "APPROVED",
            checkRollupState: "SUCCESS",
            additions: 96, deletions: 51, files: 3,
            checks: [
                CheckSummary(typename: "CheckRun", name: "CI / build", conclusion: "SUCCESS", status: "COMPLETED", url: nil),
                CheckSummary(typename: "CheckRun", name: "CI / test",  conclusion: "SUCCESS", status: "COMPLETED", url: nil),
            ]
        ),
        makePR(
            nodeId: "M_READY2",
            owner: "acme", repo: "infra", number: 412,
            title: "terraform: rotate region for warm pool",
            author: "me",
            role: .authored,
            mergeStateStatus: "CLEAN",
            reviewDecision: "APPROVED",
            checkRollupState: "SUCCESS",
            additions: 28, deletions: 12, files: 2
        ),
        makePR(
            nodeId: "M_CI_RED",
            owner: "acme", repo: "platform", number: 1849,
            title: "kernel-search: switch tantivy to stable upstream",
            author: "me",
            role: .authored,
            mergeStateStatus: "BLOCKED",
            reviewDecision: nil,
            checkRollupState: "FAILURE",
            additions: 312, deletions: 86, files: 9,
            checks: [
                CheckSummary(typename: "CheckRun", name: "CI / build", conclusion: "FAILURE", status: "COMPLETED", url: nil),
                CheckSummary(typename: "CheckRun", name: "CI / lint",  conclusion: "SUCCESS", status: "COMPLETED", url: nil),
            ]
        ),
        makePR(
            nodeId: "M_PENDING",
            owner: "acme", repo: "platform", number: 1846,
            title: "fe-app: persist Settings panel selection across launches",
            author: "me",
            role: .authored,
            mergeStateStatus: "BLOCKED",
            reviewDecision: "REVIEW_REQUIRED",
            checkRollupState: "PENDING",
            additions: 42, deletions: 11, files: 3
        ),
    ]
}

// MARK: - low-level builders

@MainActor
private func makePR(
    nodeId: String,
    owner: String,
    repo: String,
    number: Int,
    title: String,
    author: String,
    headSha: String = "abc1234",
    isDraft: Bool = false,
    role: PRRole,
    mergeStateStatus: String = "BLOCKED",
    reviewDecision: String? = "REVIEW_REQUIRED",
    checkRollupState: String = "PENDING",
    additions: Int = 50, deletions: Int = 10, files: Int = 2,
    checks: [CheckSummary] = []
) -> InboxPR {
    InboxPR(
        nodeId: nodeId, owner: owner, repo: repo, number: number,
        title: title,
        body: "## Summary\n\n- Concrete, focused changes for the screenshot fixtures.",
        url: URL(string: "https://github.com/\(owner)/\(repo)/pull/\(number)")!,
        author: author, headRef: "feat/x", baseRef: "main", headSha: headSha,
        isDraft: isDraft, role: role,
        mergeable: "MERGEABLE", mergeStateStatus: mergeStateStatus,
        reviewDecision: reviewDecision,
        checkRollupState: checkRollupState,
        totalAdditions: additions, totalDeletions: deletions, changedFiles: files,
        hasAutoMerge: false, autoMergeEnabledBy: nil,
        allCheckSummaries: checks,
        allowedMergeMethods: [.squash, .rebase],
        autoMergeAllowed: true, deleteBranchOnMerge: true
    )
}

@MainActor
private func makeAggReview(
    _ verdict: ReviewVerdict,
    confidence: Double = 0.85,
    summary: String = "Looks reasonable.",
    annotations: [DiffAnnotation] = [],
    costUsd: Double = 0.04,
    toolCallCount: Int = 2,
    toolNamesUsed: [String] = ["Read", "Grep"]
) -> AggregatedReview {
    let result = ProviderResult(
        verdict: verdict,
        confidence: confidence,
        summaryMarkdown: summary,
        annotations: annotations,
        costUsd: costUsd,
        toolCallCount: toolCallCount,
        toolNamesUsed: toolNamesUsed,
        rawJson: Data(),
        isSubscriptionAuth: true
    )
    return AggregatedReview(
        verdict: verdict,
        confidence: confidence,
        summaryMarkdown: summary,
        annotations: annotations,
        costUsd: costUsd,
        toolCallCount: toolCallCount,
        toolNamesUsed: toolNamesUsed,
        perSubreview: [SubreviewOutcome(subpath: "", result: result)],
        isSubscriptionAuth: true
    )
}

// MARK: - diff fixtures

@MainActor
private func emitterDiffHunks() -> [Hunk] {
    [
        Hunk(
            filePath: "lib/audit/emitter.go",
            oldStart: 80, oldCount: 6, newStart: 80, newCount: 10,
            lines: [
                .context("func (e *Emitter) Emit(evt Event) {"),
                .context("    if evt.Type == \"\" {"),
                .context("        return"),
                .context("    }"),
                .removed("    e.queue <- evt"),
                .added("    if evt.Payload == nil {"),
                .added("        // intentional: silent skip"),
                .added("        return"),
                .added("    }"),
                .added("    e.queue <- redact(evt, e.redactedFields)"),
            ]
        ),
        Hunk(
            filePath: "lib/audit/emitter_test.go",
            oldStart: 40, oldCount: 4, newStart: 40, newCount: 12,
            lines: [
                .context("func TestEmitter_RedactsKnownFields(t *testing.T) {"),
                .context("    e := NewEmitter(WithRedactedFields([]string{\"ssn\"}))"),
                .added("    cases := []struct{"),
                .added("        name    string"),
                .added("        in      Event"),
                .added("        want    Event"),
                .added("    }{"),
                .added("        {\"ssn redacted\", evWithSSN(), evRedactedSSN()},"),
                .added("        {\"empty redaction list\", evNoMatches(), evNoMatches()},"),
                .added("    }"),
            ]
        ),
    ]
}

@MainActor
private func invoiceDiffHunks() -> [Hunk] {
    [
        Hunk(
            filePath: "kernel-billing/invoice.go",
            oldStart: 110, oldCount: 12, newStart: 110, newCount: 18,
            lines: [
                .context("func (g *Generator) Run(ctx context.Context) error {"),
                .context("    items, err := g.collect(ctx)"),
                .context("    if err != nil { return err }"),
                .removed("    for _, it := range items {"),
                .removed("        if err := g.process(ctx, it); err != nil {"),
                .removed("            return err"),
                .removed("        }"),
                .removed("    }"),
                .added("    sem := make(chan struct{}, g.parallelism)"),
                .added("    g.eg.SetLimit(g.parallelism)"),
                .added("    for _, it := range items {"),
                .added("        sem <- struct{}{}"),
                .added("        it := it"),
                .added("        g.eg.Go(func() error {"),
                .added("            defer func() { <-sem }()"),
                .added("            return g.process(ctx, it)"),
                .added("        })"),
                .added("    }"),
                .added("    return g.eg.Wait()"),
            ]
        ),
    ]
}

@MainActor
private func virtualListDiffHunks() -> [Hunk] {
    [
        Hunk(
            filePath: "fe-app/src/InboxList.tsx",
            oldStart: 38, oldCount: 8, newStart: 38, newCount: 12,
            lines: [
                .context("export function InboxList({ prs }: Props) {"),
                .removed("  return ("),
                .removed("    <ul>"),
                .removed("      {prs.map((pr) => ("),
                .removed("        <PRRow key={pr.nodeId} pr={pr} />"),
                .removed("      ))}"),
                .removed("    </ul>"),
                .removed("  )"),
                .added("  const parentRef = useRef<HTMLDivElement>(null)"),
                .added("  const virtualizer = useVirtualizer({"),
                .added("    count: prs.length,"),
                .added("    getScrollElement: () => parentRef.current,"),
                .added("    estimateSize: () => 56,"),
                .added("  })"),
            ]
        ),
    ]
}

// MARK: - scaffolding views

/// Wraps a popover-tab view in the same chrome `PopoverView` uses (header,
/// padding, segmented bar) so the screenshot looks like the real popover.
@MainActor
private struct PopoverChrome<Content: View>: View {
    let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.headline)
                    .foregroundStyle(.tint)
                Text("PRBar")
                    .font(.headline)
                Spacer()
                Text("just now")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(16)
    }
}

private struct NoopDeliverer: NotificationDeliverer {
    func requestAuthorization() async {}
    func deliver(_ events: [NotificationEvent]) async {}
}
