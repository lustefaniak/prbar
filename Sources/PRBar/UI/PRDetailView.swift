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
    /// True when this view is hosted inside `PRDetailWindowView` — the
    /// standalone full-size window. Hides the "open in window" button
    /// (we're already in one) and rebinds the back button to close the
    /// window instead of returning to the list.
    var inWindow: Bool = false

    @Environment(PRPoller.self) private var poller
    @Environment(ReviewQueueWorker.self) private var queue
    @Environment(DiffStore.self) private var diffStore

    @State private var bodyDraft: String = ""
    /// Tracks the SHA whose AI summary was used to seed `bodyDraft` so we
    /// don't overwrite user edits when SwiftUI re-evaluates onChange, but
    /// do re-seed when a fresh review for a new commit lands.
    @State private var bodyDraftSeededForSha: String? = nil
    @AppStorage("postIncludesAISummary") private var postIncludesAISummary = false
    @Environment(\.openWindow) private var openWindow
    @State private var showActionPicker: Bool = false
    @State private var descriptionExpanded: Bool = false
    @State private var branchCopied: Bool = false

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
        return queue.reviews[pr.nodeId]?.latestPrior?.aggregated
    }

    private var reviewStatus: ReviewState.Status? {
        queue.reviews[pr.nodeId]?.status
    }

    /// Prior completed review captured when the PR's head moved. Drives
    /// the retriage banner + lets us keep showing the previous verdict
    /// while the new run is in flight.
    private var priorReview: PriorReview? {
        queue.reviews[pr.nodeId]?.latestPrior
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
                                CIStatusView(checks: pr.allCheckSummaries, pr: pr)
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
        .onAppear {
            diffStore.ensureLoaded(for: pr)
            migrateLegacyPostBodyPreference()
            seedBodyDraftFromAIIfNeeded()
        }
        .onChange(of: pr.headSha) { _, _ in diffStore.ensureLoaded(for: pr) }
        .onChange(of: pr.nodeId) { _, _ in
            // Switching PRs in the popover: drop the per-PR draft so the
            // next PR starts clean.
            bodyDraft = ""
            bodyDraftSeededForSha = nil
            seedBodyDraftFromAIIfNeeded()
        }
        .onChange(of: review?.summaryMarkdown ?? "") { _, _ in
            seedBodyDraftFromAIIfNeeded()
        }
        .onChange(of: postIncludesAISummary) { _, _ in
            seedBodyDraftFromAIIfNeeded()
        }
    }

    /// One-shot migration of the old `approveIncludesComment` @AppStorage
    /// key to the new `postIncludesAISummary` key. Runs once per launch
    /// per detail view; cheap (UserDefaults reads only).
    private func migrateLegacyPostBodyPreference() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "postIncludesAISummary") == nil,
              let legacy = defaults.object(forKey: "approveIncludesComment") as? Bool
        else { return }
        defaults.set(legacy, forKey: "postIncludesAISummary")
    }

    /// Pre-fill the editable body with the AI's summary the first time
    /// we see a completed review for this PR's current head, IF the
    /// setting opts in. Never overwrites user edits and never re-seeds
    /// for the same SHA twice.
    private func seedBodyDraftFromAIIfNeeded() {
        guard postIncludesAISummary,
              let summary = review?.summaryMarkdown,
              !summary.isEmpty
        else { return }
        let sha = queue.reviews[pr.nodeId]?.headSha ?? pr.headSha
        if bodyDraftSeededForSha == sha { return }
        if !bodyDraft.isEmpty { return }
        bodyDraft = summary
        bodyDraftSeededForSha = sha
    }

    // MARK: - sections

    private var navHeader: some View {
        HStack {
            if !inWindow {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
            }

            Spacer()
            Text(verbatim: "\(pr.nameWithOwner) #\(pr.numberString)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if !inWindow {
                Button {
                    openWindow(id: PRDetailWindowID.id, value: pr.nodeId)
                    // Dismiss the popover so the user lands focused on
                    // the new window rather than seeing the popover
                    // hang around behind it.
                    (NSApp.delegate as? AppDelegate)?.dismissPopover()
                } label: {
                    Image(systemName: "macwindow.on.rectangle")
                }
                .buttonStyle(.borderless)
                .help("Open in separate window")
            }

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
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(pr.headRef, forType: .string)
                    branchCopied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        branchCopied = false
                    }
                } label: {
                    Image(systemName: branchCopied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help(branchCopied ? "Copied" : "Copy branch name")
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
                        .fixedSize(horizontal: false, vertical: true)
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
                .frame(maxWidth: .infinity, alignment: .leading)
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
            Text("Post review")
                .font(.subheadline.bold())

            // Single editable body. Pre-seeded with the AI summary on
            // review-completion when `postIncludesAISummary` is on; user
            // is free to edit, replace, or clear before posting.
            TextEditor(text: $bodyDraft)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 60, maxHeight: 160)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(.secondary.opacity(0.2))
                )
                .help("Body for the review. Pre-fills with the AI summary when the matching setting is on; edit freely.")

            actionsToolbar
        }
    }

    @ViewBuilder
    private var actionsToolbar: some View {
        let isPosting = poller.postingReviewPRs.contains(pr.nodeId)
        let aiVerdict = review?.verdict
        let preferredAction: ReviewActionKind? = aiVerdict.flatMap(reviewAction(for:))

        HStack(spacing: 6) {
            actionButton(.approve, isPreferred: preferredAction == .approve, isPosting: isPosting)
            actionButton(.comment, isPreferred: preferredAction == .comment, isPosting: isPosting)
            actionButton(.requestChanges, isPreferred: preferredAction == .requestChanges, isPosting: isPosting)

            if !bodyDraft.isEmpty {
                Button {
                    bodyDraft = ""
                    bodyDraftSeededForSha = nil
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Clear body")
                .disabled(isPosting)
            }

            if isPosting {
                ProgressView().controlSize(.small)
            }

            Spacer()
        }

        if let err = poller.lastError {
            Text(err)
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private func actionButton(
        _ kind: ReviewActionKind,
        isPreferred: Bool,
        isPosting: Bool
    ) -> some View {
        let needsBody = (kind == .comment) // GitHub rejects empty Comment reviews.
        let disabled = isPosting || (needsBody && bodyDraft.isEmpty)

        Group {
            if isPreferred {
                Button {
                    postReview(kind: kind)
                } label: {
                    actionButtonLabel(kind)
                }
                .buttonStyle(.borderedProminent)
                .tint(actionButtonTint(kind))
            } else {
                Button {
                    postReview(kind: kind)
                } label: {
                    actionButtonLabel(kind)
                }
                .buttonStyle(.bordered)
                .tint(actionButtonTint(kind))
            }
        }
        .disabled(disabled)
        .help(actionButtonHelp(kind, isPreferred: isPreferred, needsBody: needsBody))
    }

    @ViewBuilder
    private func actionButtonLabel(_ kind: ReviewActionKind) -> some View {
        switch kind {
        case .approve:
            Label("Approve", systemImage: "hand.thumbsup")
        case .comment:
            Label("Comment", systemImage: "bubble.left")
        case .requestChanges:
            Label("Request changes", systemImage: "hand.thumbsdown")
        }
    }

    private func actionButtonTint(_ kind: ReviewActionKind) -> Color {
        switch kind {
        case .approve:        return .green
        case .comment:        return .blue
        case .requestChanges: return .orange
        }
    }

    private func actionButtonHelp(_ kind: ReviewActionKind, isPreferred: Bool, needsBody: Bool) -> String {
        let base: String
        switch kind {
        case .approve:        base = "Approve this PR"
        case .comment:        base = "Post a Comment review"
        case .requestChanges: base = "Request changes"
        }
        var extra: [String] = []
        if isPreferred { extra.append("matches the AI verdict") }
        if needsBody && bodyDraft.isEmpty { extra.append("body required") }
        return extra.isEmpty ? base : "\(base) — \(extra.joined(separator: "; "))"
    }

    /// Informational verdict pill. Posting now happens through the
    /// unified action row in `actionsSection`, where the matching button
    /// gets prominent styling. The pill itself is a plain badge — no
    /// click target — so the user always sees both the AI's verdict and
    /// the posting controls without confusion about what one click does.
    @ViewBuilder
    private func verdictBadge(_ verdict: ReviewVerdict, summary _: String) -> some View {
        let (label, color) = verdictAppearance(verdict)
        HStack(spacing: 4) {
            Text(label)
        }
        .font(.caption.bold())
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color, in: Capsule())
        .help("AI verdict — use the buttons below to post a review")
    }

    private func postReview(kind: ReviewActionKind) {
        poller.postReview(pr, kind: kind, body: bodyDraft)
        bodyDraft = ""
        bodyDraftSeededForSha = nil
        onPostedAction()
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
