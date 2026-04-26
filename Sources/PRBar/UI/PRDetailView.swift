import SwiftUI
import AppKit

/// Detail view for one PR. Shows the AI review (if any) plus action
/// buttons. Replaces the popover's tab list when a row is selected.
struct PRDetailView: View {
    let pr: InboxPR
    let onBack: () -> Void
    /// Called after the user posts a review action. The popover decides
    /// whether to advance to the next ready PR or fall back to `onBack`
    /// based on the user's "Advance to next ready PR" preference. Default
    /// no-op so previews / fallback callers don't need to wire it.
    var onPostedAction: () -> Void = {}
    /// When true, swap the inner ScrollView for a flat VStack so
    /// `ImageRenderer` can capture every section in one frame for
    /// `ScreenshotTests`. Production callers leave this false.
    var screenshotMode: Bool = false

    @Environment(PRPoller.self) private var poller
    @Environment(ReviewQueueWorker.self) private var queue
    @Environment(DiffStore.self) private var diffStore

    @State private var bodyDraft: String = ""
    @State private var showActionPicker: Bool = false
    @State private var descriptionExpanded: Bool = false

    /// Set when the user clicks an annotation row → drives scroll +
    /// expand-bubble in the diff. Cleared after a short delay so the
    /// same annotation can be re-clicked to re-jump.
    @State private var focusedDiffKey: String? = nil

    private var review: AggregatedReview? {
        if case .completed(let agg) = queue.reviews[pr.nodeId]?.status {
            return agg
        }
        // While retriaging, surface the prior review so annotations stay
        // visible against the diff. The new run replaces this on success;
        // on failure the user keeps their last good triage.
        return queue.reviews[pr.nodeId]?.priorReview?.aggregated
    }

    private var reviewStatus: ReviewState.Status? {
        queue.reviews[pr.nodeId]?.status
    }

    /// Prior completed review captured when the PR's head moved. Drives
    /// the retriage banner + lets us keep showing the previous verdict
    /// while the new run is in flight.
    private var priorReview: PriorReview? {
        queue.reviews[pr.nodeId]?.priorReview
    }

    /// True when the cached review was for an earlier commit than the
    /// PR's current head — i.e. the AI's verdict is for a stale snapshot
    /// and a fresh re-triage is appropriate.
    private var isReviewStale: Bool {
        guard let s = queue.reviews[pr.nodeId] else { return false }
        guard case .completed = s.status else { return false }
        return s.headSha != pr.headSha
    }

    private var cachedReviewedSha: String? {
        queue.reviews[pr.nodeId]?.headSha
    }

    /// Approve / Comment / Request-changes only make sense when the user
    /// is being asked to review. GitHub blocks self-review on PRs you
    /// authored anyway, so hiding the buttons removes a click-then-fail
    /// path. `.both` (author + asked to review) keeps them — that's a
    /// genuine cross-team setup.
    private var showsReviewActions: Bool {
        pr.role == .reviewRequested || pr.role == .both
    }

    var body: some View {
        if screenshotMode {
            screenshotBody
        } else {
            productionBody
        }
    }

    @ViewBuilder
    private var productionBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            navHeader

            Divider()

            prHeader

            Divider()

            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            // Anchor target for the scroll-to-top button.
                            Color.clear.frame(height: 0).id("top")
                            if !pr.body.isEmpty {
                                descriptionSection
                                Divider()
                            }
                            if !pr.allCheckSummaries.isEmpty {
                                CIStatusView(checks: pr.allCheckSummaries)
                                Divider()
                            }
                            aiSection
                            Divider()
                            diffSection
                            if showsReviewActions {
                                Divider()
                                actionsSection
                            }
                        }
                    }
                    scrollToTopButton(proxy: proxy)
                }
                .onChange(of: focusedDiffKey) { _, newKey in
                    guard let key = newKey else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(key, anchor: .center)
                    }
                    // Clear the focus shortly after so re-clicking the
                    // same annotation triggers another scroll. SwiftUI
                    // only fires onChange on actual value changes.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        focusedDiffKey = nil
                    }
                }
            }
        }
        .onAppear { diffStore.ensureLoaded(for: pr) }
        .onChange(of: pr.headSha) { _, _ in diffStore.ensureLoaded(for: pr) }
    }

    /// Flat-layout body used when `screenshotMode == true`. Mirrors the
    /// production sections (PR header, CI, AI verdict, annotations,
    /// diff, actions) but skips the nav chrome and the ScrollView
    /// wrapper — `ImageRenderer` clips ScrollView content to the
    /// proposed size, so a flat tree is what marketing screenshots
    /// (and visual regression diffs) need.
    @ViewBuilder
    private var screenshotBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            prHeader
            Divider()
            if !pr.body.isEmpty {
                descriptionSection
                Divider()
            }
            if !pr.allCheckSummaries.isEmpty {
                CIStatusView(checks: pr.allCheckSummaries)
                Divider()
            }
            aiSection
            Divider()
            diffSection
            if showsReviewActions {
                Divider()
                actionsSection
            }
        }
        .padding(16)
    }

    // MARK: - sections

    private var navHeader: some View {
        HStack {
            Button(action: onBack) {
                Label("Back", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)

            Spacer()
            Text(verbatim: "\(pr.nameWithOwner) #\(pr.numberString)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Button {
                NSWorkspace.shared.open(pr.url)
            } label: {
                Image(systemName: "safari")
            }
            .buttonStyle(.borderless)
            .help("Open in browser")
        }
    }

    private var prHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(pr.title)
                .font(.headline)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Text("@\(pr.author)")
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.secondary)
                Text("`\(pr.baseRef)` ← `\(pr.headRef)`")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.secondary)
                Text("+\(pr.totalAdditions) -\(pr.totalDeletions) (\(pr.changedFiles) files)")
                    .foregroundStyle(.secondary)
                if pr.isDraft {
                    Text("draft")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .background(.secondary.opacity(0.15), in: Capsule())
                }
            }
            .font(.caption)
        }
    }

    /// PR description rendered as GitHub-flavored Markdown via
    /// `MarkdownText` (which wraps `swift-markdown-ui`). Headings,
    /// fenced code, lists, tables, blockquotes, task lists all
    /// render as native SwiftUI.
    ///
    /// Collapsed to ~6 lines by default; "Show more / Show less"
    /// toggles full height. Body is selectable so users can copy.
    @ViewBuilder
    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Description")
                    .font(.subheadline.bold())
                Spacer()
                Button(descriptionExpanded ? "Show less" : "Show more") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        descriptionExpanded.toggle()
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            // Selection (.textSelection) and click-to-expand fight
            // each other: with selection enabled, every click drops a
            // text-cursor caret instead of triggering the gesture, and
            // moving the mouse during click starts a selection drag.
            // Resolve cleanly: when collapsed, the body is a tap target
            // (no selection); when expanded, switch to selectable text
            // (no tap, copy/paste works) and rely on "Show less".
            if descriptionExpanded {
                MarkdownText(raw: pr.body)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        descriptionExpanded = true
                    }
                } label: {
                    // Collapsed preview renders the full Markdown but
                    // clips to a fixed height with a fade-out mask at
                    // the bottom — `Markdown`'s per-block VStack layout
                    // ignores SwiftUI's `lineLimit`, so we clip
                    // visually rather than line-count.
                    MarkdownText(raw: pr.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(maxHeight: 110, alignment: .top)
                        .clipped()
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0.0),
                                    .init(color: .black, location: 0.75),
                                    .init(color: .black.opacity(0.0), location: 1.0),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("AI Review")
                    .font(.subheadline.bold())
                if let providerId = queue.reviews[pr.nodeId]?.providerId {
                    Text(providerId.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.secondary.opacity(0.12), in: Capsule())
                        .help("AI provider that ran this review")
                }
                Spacer()
                rerunMenu
            }

            if isReviewStale, let oldSha = cachedReviewedSha {
                staleBanner(oldSha: oldSha)
            }

            switch reviewStatus {
            case .none:
                Text("No review yet — press Re-run to start one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .queued:
                inProgressView(
                    label: priorReview != nil
                        ? "Queued — retriaging the new commits…"
                        : "Queued…"
                )

            case .running:
                inProgressView(
                    label: priorReview != nil
                        ? "Reviewing the new commits…"
                        : "Reviewing…"
                )

            case .failed(let msg):
                VStack(alignment: .leading, spacing: 8) {
                    Text("Review failed: \(msg)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(4)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if let prior = priorReview {
                        priorReviewBanner(prior)
                        completedReviewSection(prior.aggregated)
                    }
                }

            case .completed(let agg):
                completedReviewSection(agg)
            }
        }
    }

    /// In-flight review shows: spinner + label + (when this is a
    /// retriage with a prior verdict) the previous review kept visible
    /// underneath. Avoids the "blank AI section" gap on re-run.
    @ViewBuilder
    private func inProgressView(label: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            if let progress = queue.liveProgress[pr.nodeId] {
                liveProgressView(progress)
            }
            if let prior = priorReview {
                priorReviewBanner(prior)
                completedReviewSection(prior.aggregated)
            }
        }
    }

    @ViewBuilder
    private func liveProgressView(_ progress: ReviewProgress) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if progress.toolCallCount > 0 {
                    Label("\(progress.toolCallCount) tool\(progress.toolCallCount == 1 ? "" : "s")",
                          systemImage: "wrench.and.screwdriver")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Tools used so far: \(progress.toolNamesUsed.joined(separator: ", "))")
                }
                if let cost = progress.costUsdSoFar {
                    Text(String(format: "$%.4f", cost))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if let last = progress.toolNamesUsed.last {
                    Text("· running `\(last)`")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func priorReviewBanner(_ prior: PriorReview) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.orange)
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text("Showing previous review for `\(String(prior.headSha.prefix(7)))`.")
                    .font(.caption)
                Text("New review will incorporate prior verdict + summary as context.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(8)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Re-run as a split menu: primary click re-runs with the
    /// repo/app default provider; the dropdown lets the user pick a
    /// specific provider for this single run (e.g. "compare claude
    /// against codex on this PR"). Disabled while in flight.
    @ViewBuilder
    private var rerunMenu: some View {
        let inFlight: Bool = {
            if case .running = reviewStatus { return true }
            if case .queued  = reviewStatus { return true }
            return false
        }()
        Menu {
            ForEach(ProviderID.allCases, id: \.self) { provider in
                Button {
                    queue.enqueue(pr, force: true, providerOverride: provider)
                } label: {
                    Label("Re-run with \(provider.displayName)", systemImage: "sparkles")
                }
            }
        } label: {
            Label("Re-run", systemImage: "arrow.clockwise")
                .labelStyle(.titleAndIcon)
                .font(.caption)
        } primaryAction: {
            queue.enqueue(pr, force: true)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .disabled(inFlight)
    }

    @ViewBuilder
    private func staleBanner(oldSha: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.orange)
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text("Review is for an earlier commit (\(String(oldSha.prefix(7)))).")
                    .font(.caption)
                Text("Press Re-run to triage the latest changes.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(8)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func completedReviewSection(_ agg: AggregatedReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                verdictBadge(agg.verdict, summary: agg.summaryMarkdown)
                Text(String(format: "%.0f%% confident", agg.confidence * 100))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if agg.costUsd > 0 {
                    Text(String(format: "$%.4f", agg.costUsd))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(agg.isSubscriptionAuth ? Color.secondary.opacity(0.5) : .secondary)
                        .help(agg.isSubscriptionAuth
                              ? "API-equivalent cost. Running on subscription auth — not actually billed per-token."
                              : "Total cost")
                }
                if agg.toolCallCount > 0 {
                    Text("\(agg.toolCallCount) tool\(agg.toolCallCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Tool calls used: \(agg.toolNamesUsed.joined(separator: ", "))")
                }
            }
            MarkdownText(raw: agg.summaryMarkdown)
                .font(.callout)
            if !agg.annotations.isEmpty {
                AnnotationsSummaryView(
                    annotations: agg.annotations,
                    onLocate: { ann in
                        // Land on the last covered line so multi-line
                        // ranges still highlight the bottom edge of the
                        // span. Scroller centers it; close enough to read.
                        focusedDiffKey = DiffView.anchorKey(
                            path: ann.path, newLine: ann.lineEnd
                        )
                    }
                )
            }
            if agg.perSubreview.count > 1 {
                SubreviewBreakdownView(outcomes: agg.perSubreview)
            }
            activityDisclosure(for: agg)
        }
    }

    @ViewBuilder
    private func activityDisclosure(for agg: AggregatedReview) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(agg.perSubreview.enumerated()), id: \.offset) { _, outcome in
                    if agg.perSubreview.count > 1 {
                        Text(outcome.subpath.isEmpty ? "(repo root)" : outcome.subpath)
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                    }
                    let stream = String(data: outcome.result.rawJson, encoding: .utf8) ?? ""
                    ReviewTraceView(trace: ReviewTraceParser.parse(stream))
                }
            }
            .padding(.top, 4)
        } label: {
            Text("How the AI reviewed")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var diffSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Diff")
                    .font(.subheadline.bold())
                Spacer()
                Button {
                    diffStore.invalidate(for: pr)
                    diffStore.ensureLoaded(for: pr)
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Re-fetch diff")
            }

            switch diffStore.status(for: pr) {
            case .idle, .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading diff…").font(.caption).foregroundStyle(.secondary)
                }
            case .failed(let msg):
                Text("Diff failed: \(msg)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            case .loaded(let hunks):
                DiffView(
                    hunks: hunks,
                    annotations: review?.annotations ?? [],
                    subpaths: subpathsFromReview(),
                    focusedKey: $focusedDiffKey
                )
            }
        }
    }

    /// Floating button bottom-right of the detail scroller. Always
    /// rendered; visually unobtrusive (small, slightly transparent) so
    /// it doesn't get in the way of short PRs but is right there when
    /// the diff scrolls past several screens. Click → scroll to top.
    @ViewBuilder
    private func scrollToTopButton(proxy: ScrollViewProxy) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo("top", anchor: .top)
            }
        } label: {
            Image(systemName: "arrow.up.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
        .padding(8)
        .opacity(0.7)
        .help("Scroll to top")
    }

    private func subpathsFromReview() -> [String] {
        guard let outcomes = review?.perSubreview, outcomes.count > 1 else { return [] }
        return outcomes.map(\.subpath)
    }

    @ViewBuilder
    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Actions")
                .font(.subheadline.bold())

            // Optional comment body when the chosen action wants one.
            // ImageRenderer can't render an NSTextView, so screenshot
            // mode swaps in a static placeholder that visually matches
            // the rounded-border editor.
            if screenshotMode {
                Text("Optional body for Approve / Comment / Request changes…")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                    .padding(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(.secondary.opacity(0.2))
                    )
            } else {
                TextEditor(text: $bodyDraft)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(.secondary.opacity(0.2))
                    )
                    .help("Optional body for Approve/Comment/Request changes.")
            }

            HStack(spacing: 6) {
                let isPosting = poller.postingReviewPRs.contains(pr.nodeId)

                Button {
                    poller.postReview(pr, kind: .approve, body: bodyDraft)
                    bodyDraft = ""
                    onPostedAction()
                } label: {
                    Label("Approve", systemImage: "hand.thumbsup")
                }
                .disabled(isPosting)

                Button {
                    poller.postReview(pr, kind: .comment, body: bodyDraft)
                    bodyDraft = ""
                    onPostedAction()
                } label: {
                    Label("Comment", systemImage: "bubble.left")
                }
                .disabled(isPosting || bodyDraft.isEmpty)
                .help("Comment requires a body.")

                Button {
                    poller.postReview(pr, kind: .requestChanges, body: bodyDraft)
                    bodyDraft = ""
                    onPostedAction()
                } label: {
                    Label("Request changes", systemImage: "hand.thumbsdown")
                }
                .disabled(isPosting)

                if isPosting {
                    ProgressView().controlSize(.small)
                }
            }

            if let err = poller.lastError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    /// The verdict badge under "AI Review" doubles as a one-click way
    /// to post that exact verdict back to GitHub with the AI's summary
    /// as the body. Only fires when (a) we're allowed to review this PR
    /// (not own-only) and (b) the verdict maps to an actual review action
    /// (`abstain` does not). On unauthorised cases it renders as a plain
    /// label so the user still sees what the AI said.
    @ViewBuilder
    private func verdictBadge(_ verdict: ReviewVerdict, summary: String) -> some View {
        let (label, color) = verdictAppearance(verdict)
        let isPosting = poller.postingReviewPRs.contains(pr.nodeId)
        let action = reviewAction(for: verdict)

        let pill = HStack(spacing: 4) {
            Text(label)
            if showsReviewActions, action != nil {
                Image(systemName: "paperplane.fill")
                    .font(.caption2)
            }
        }
        .font(.caption.bold())
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color, in: Capsule())

        if showsReviewActions, let action {
            Button {
                poller.postReview(pr, kind: action, body: summary)
                onPostedAction()
            } label: {
                pill
            }
            .buttonStyle(.plain)
            .disabled(isPosting)
            .opacity(isPosting ? 0.5 : 1)
            .help("Post this AI review to GitHub as \(action.displayName)")
        } else {
            pill
        }
    }

    private func reviewAction(for verdict: ReviewVerdict) -> ReviewActionKind? {
        switch verdict {
        case .approve:        return .approve
        case .comment:        return .comment
        case .requestChanges: return .requestChanges
        case .abstain:        return nil
        }
    }

    private func verdictAppearance(_ v: ReviewVerdict) -> (String, Color) {
        // Labels mirror GitHub's own review action verbs verbatim — no
        // ALL CAPS, no abbreviations — so clicking the pill posts what
        // the label literally says. "Abstain" has no GitHub equivalent;
        // shown as informational only (the badge isn't clickable in
        // that case — see `reviewAction(for:)`).
        switch v {
        case .approve:        return ("Approve", .green)
        case .comment:        return ("Comment", .blue)
        case .requestChanges: return ("Request changes", .red)
        case .abstain:        return ("Abstain", .gray)
        }
    }
}
