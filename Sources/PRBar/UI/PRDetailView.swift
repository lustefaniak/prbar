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
    /// Called when the user skips this PR for now. The popover records
    /// the skip for the current review session and advances to the next
    /// non-skipped review-requested PR (returning to the list, and
    /// forgetting the skips, once none remain). Default no-op so the
    /// standalone window / previews don't need to wire it.
    var onSkip: () -> Void = {}
    /// True when this view is hosted inside `PRDetailWindowView` — the
    /// standalone full-size window. Hides the "open in window" button
    /// (we're already in one) and rebinds the back button to close the
    /// window instead of returning to the list.
    var inWindow: Bool = false

    @Environment(PRPoller.self) private var poller
    @Environment(ReviewQueueWorker.self) private var queue
    @Environment(ActionQueue.self) private var actionQueue
    @Environment(DiffStore.self) private var diffStore
    @Environment(RepoConfigStore.self) private var repoConfigs

    /// Global "skip merge confirmation" default; a per-repo
    /// `RepoConfig.skipMergeConfirmation` overrides it.
    @AppStorage("skipMergeConfirmation") private var skipMergeConfirmationGlobal = false

    @State private var bodyDraft: String = ""
    /// Tracks the SHA whose AI summary was used to seed `bodyDraft` so we
    /// don't overwrite user edits when SwiftUI re-evaluates onChange, but
    /// do re-seed when a fresh review for a new commit lands.
    @State private var bodyDraftSeededForSha: String? = nil
    /// App-wide preference (Settings → General). Controls whether the
    /// AI summary pre-fills the review body by default. The action bar
    /// also exposes a per-PR override (`includeAISummary`) so the user
    /// can flip the default for the current PR without rummaging in
    /// Settings.
    @AppStorage("postIncludesAISummary") private var postIncludesAISummary = true
    /// Persisted across launches so the user can opt out of the
    /// "include N annotations as inline comments" default behaviour.
    @AppStorage("postIncludesInlineAnnotations") private var includeInlineAnnotations = true
    /// Per-PR override of `postIncludesAISummary`. `nil` = follow the
    /// app-wide default; `true` / `false` = explicit override for this
    /// PR's lifetime in the popover. Reset on PR switch.
    @State private var includeAISummaryOverride: Bool? = nil
    @Environment(\.openWindow) private var openWindow
    @State private var bodyExpanded: Bool = false
    @State private var descriptionExpanded: Bool = false
    /// Reviews & Comments default to collapsed so they don't push the
    /// action buttons down the page — the collapsed header still shows a
    /// per-reviewer verdict chip summary. Reset on PR switch.
    @State private var reviewsExpanded: Bool = false
    @State private var branchCopied: Bool = false

    /// Merge confirmation dialog state (own PRs). Mirrors `PRRowView`'s
    /// pattern: stash the chosen method, then confirm before enqueuing the
    /// immediate merge.
    @State private var showMergeConfirm = false
    @State private var pendingMergeMethod: MergeMethod = .squash

    /// Set when the user clicks an annotation row → drives scroll +
    /// expand-bubble in the diff. Cleared after a short delay so the
    /// same annotation can be re-clicked to re-jump.
    @State private var focusedDiffKey: String? = nil

    /// Per-PR opt-in to render a diff above `maxInlineDiffLines` inline.
    /// Huge diffs are collapsed to a "view on GitHub" card by default
    /// because DiffView builds every line eagerly inside the scroll
    /// container, and a multi-thousand-line diff churns CALayers badly
    /// during scroll (the popover goes sluggish and rows visibly
    /// unload/reload). Reset on PR switch.
    @State private var forceRenderLargeDiff = false

    /// Above this many total diff lines the inline render is replaced by
    /// a GitHub link unless the user clicks "Render anyway".
    private static let maxInlineDiffLines = 1500

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

    /// Merge / auto-merge controls only make sense on PRs the viewer
    /// authored (GitHub lets you merge your own PR; `.both` keeps both
    /// the review card and the merge card — a genuine cross-team setup).
    private var showsMergeActions: Bool {
        pr.role == .authored || pr.role == .both
    }

    /// Effective per-PR include-AI-summary state: explicit override
    /// when present, else the global setting.
    private var includeAISummary: Bool {
        includeAISummaryOverride ?? postIncludesAISummary
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
                        // LazyVStack + Section/header pinning gives us
                        // "sticky on scroll" for the action bar: it
                        // sits naturally below the AI section when the
                        // user is at the top, and pins to the viewport
                        // top once they scroll into the diff so Approve
                        // stays one click away. Plain VStack doesn't
                        // honour `pinnedViews`.
                        LazyVStack(alignment: .leading, spacing: 12) {
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
                            if !activityEntries.isEmpty {
                                humanReviewsSection
                                Divider()
                            }
                            aiSection

                            Divider()
                            diffSection
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

            // Always-visible action footer: the card lives outside the
            // ScrollView so it stays pinned to the bottom of the popover
            // regardless of scroll position. Being a separate region (not
            // an overlay on scrolled content) sidesteps the translucent
            // bleed-through that plagued the old top-pinned header.
            if showsReviewActions {
                actionsCard
            }
            if showsMergeActions {
                mergeCard
            }
        }
        .confirmationDialog(
            "\(pendingMergeMethod.displayName) #\(pr.numberString)?",
            isPresented: $showMergeConfirm,
            titleVisibility: .visible
        ) {
            Button(pendingMergeMethod.displayName, role: .destructive) {
                rememberMergeMethod(pendingMergeMethod)
                actionQueue.enqueue(pr, kind: .merge(method: pendingMergeMethod))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(pr.title)\n\(pr.nameWithOwner) → \(pr.baseRef)")
        }
        .onAppear {
            diffStore.ensureLoaded(for: pr)
            seedBodyDraftFromAIIfNeeded()
            // Snapshot in `poller.prs` may be up to ~60s stale by the
            // time the user clicks. Kick a single-PR refresh in the
            // background so reviewDecision / mergeStateStatus / CI
            // status reflect reality without waiting for the next
            // scheduled poll.
            poller.refreshPR(pr)
        }
        .onChange(of: pr.headSha) { _, _ in diffStore.ensureLoaded(for: pr) }
        .onChange(of: pr.nodeId) { _, _ in
            // Switching PRs in the popover: drop the per-PR draft so the
            // next PR starts clean. Also drop the per-PR include-summary
            // override so the global setting takes over for the next PR
            // (overrides are intentionally short-lived).
            bodyDraft = ""
            bodyDraftSeededForSha = nil
            includeAISummaryOverride = nil
            reviewsExpanded = false
            forceRenderLargeDiff = false
            seedBodyDraftFromAIIfNeeded()
        }
        .onChange(of: review?.summaryMarkdown ?? "") { _, _ in
            seedBodyDraftFromAIIfNeeded()
        }
    }

    /// Pre-fill the editable body with the AI's summary the first time
    /// we see a completed review for this PR's current head — only
    /// when `includeAISummary` is true (global setting + per-PR override).
    /// Never overwrites user edits and never re-seeds for the same SHA
    /// twice. The body is then sent verbatim when the user clicks the
    /// primary post button — no copy-paste required for the common path.
    private func seedBodyDraftFromAIIfNeeded() {
        guard includeAISummary else { return }
        guard let summary = review?.summaryMarkdown, !summary.isEmpty else { return }
        let sha = queue.reviews[pr.nodeId]?.headSha ?? pr.headSha
        if bodyDraftSeededForSha == sha { return }
        if !bodyDraft.isEmpty { return }
        bodyDraft = summary
        bodyDraftSeededForSha = sha
    }

    /// React to the user flipping the per-PR "Include AI summary"
    /// toggle: ON seeds the body, OFF clears it (so they can see the
    /// effect immediately rather than discovering it at post time).
    /// Only clears when the body matches the AI summary — preserves
    /// any free-form edits the user typed.
    private func handleIncludeSummaryToggle(_ newValue: Bool) {
        includeAISummaryOverride = newValue
        if newValue {
            bodyDraftSeededForSha = nil
            seedBodyDraftFromAIIfNeeded()
        } else if bodyDraft == (review?.summaryMarkdown ?? "<n/a>") || bodyDraft.isEmpty {
            bodyDraft = ""
            bodyDraftSeededForSha = nil
        }
    }

    // MARK: - sections

    /// Anything pending that the user can't act on yet — surfaced as a
    /// small spinner + label in the nav bar so the view never looks
    /// "stuck" while async work is in flight. Distinct from the per-
    /// section spinners (diff "Loading diff…", AI "Reviewing…") which
    /// stay where they are; this is the at-a-glance pulse.
    private var inFlightSummary: String? {
        var parts: [String] = []
        if poller.refreshingPRs.contains(pr.nodeId) { parts.append("PR") }
        if case .loading = diffStore.status(for: pr) { parts.append("diff") }
        if case .running = reviewStatus { parts.append("AI") }
        if case .queued  = reviewStatus { parts.append("AI") }
        return parts.isEmpty ? nil : "Loading \(parts.joined(separator: ", "))…"
    }

    private var navHeader: some View {
        HStack {
            if !inWindow {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)

                if showsReviewActions {
                    Button(action: onSkip) {
                        Label("Skip for now", systemImage: "forward.end")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderless)
                    .help("Skip this PR for now — jump to the next review-requested PR. Skipped PRs aren't shown again until the list is empty, then the skips are forgotten.")
                }
            }

            if let summary = inFlightSummary {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }

            Spacer()
            Text(verbatim: "\(pr.nameWithOwner) #\(pr.numberString)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Button {
                poller.refreshPR(pr, force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(poller.refreshingPRs.contains(pr.nodeId))
            .help("Refresh this PR now — re-pulls review decision, merge state, CI status, and auto-merge state")

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
                if let mine = pr.myLastReview {
                    myReviewBadge(mine)
                }
            }
            .font(.caption)
        }
    }

    /// "You already reviewed" pill, surfaced at the top so it's visible
    /// before the user scrolls into the reviews list or reaches for the
    /// Approve button. Tinted by the verdict of the viewer's latest review.
    @ViewBuilder
    private func myReviewBadge(_ review: PRReviewSummary) -> some View {
        let style = reviewStateStyle(review.state)
        HStack(spacing: 3) {
            Image(systemName: style.icon)
            Text("You \(style.label)")
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(style.color)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(style.color.opacity(0.15), in: Capsule())
        .help(review.submittedAt.map { "You reviewed \($0.formatted(.relative(presentation: .named)))" }
            ?? "You already reviewed this PR")
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

    // MARK: - human reviews & comments

    /// One entry in the merged people-activity timeline: either a
    /// submitted review (verdict + optional body) or a conversation
    /// comment. Built from `pr.humanReviews` + `pr.issueComments`.
    private struct ActivityEntry: Identifiable {
        enum Kind {
            case review(PRReviewSummary)
            case comment(PRCommentSummary)
        }
        let id: String
        let date: Date?
        let kind: Kind
    }

    /// Reviews and comments merged into one chronological list,
    /// oldest-first (matches GitHub's conversation order).
    private var activityEntries: [ActivityEntry] {
        var items: [ActivityEntry] = []
        for r in pr.humanReviews {
            items.append(ActivityEntry(id: r.id, date: r.submittedAt, kind: .review(r)))
        }
        for c in pr.issueComments {
            items.append(ActivityEntry(id: c.id, date: c.createdAt, kind: .comment(c)))
        }
        return items.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    /// Visual treatment for a review state — shared by the timeline rows
    /// and the header "You …" badge so the verdict reads the same in both.
    private func reviewStateStyle(_ state: String) -> (icon: String, label: String, color: Color) {
        switch state.uppercased() {
        case "APPROVED":          return ("checkmark.seal.fill", "approved", .green)
        case "CHANGES_REQUESTED": return ("xmark.octagon.fill", "requested changes", .red)
        case "DISMISSED":         return ("slash.circle", "review dismissed", .secondary)
        case "PENDING":           return ("pencil.circle", "pending review", .secondary)
        default:                  return ("text.bubble", "commented", .secondary)
        }
    }

    /// Latest review per distinct author, oldest-first — drives the
    /// collapsed chip summary (one chip per reviewer, showing their
    /// current verdict) without repeating a reviewer who reviewed twice.
    private var reviewerSummaries: [PRReviewSummary] {
        var latestByAuthor: [String: PRReviewSummary] = [:]
        for r in pr.humanReviews { latestByAuthor[r.author] = r }
        return latestByAuthor.values.sorted {
            ($0.submittedAt ?? .distantPast) < ($1.submittedAt ?? .distantPast)
        }
    }

    @ViewBuilder
    private func reviewerChip(_ r: PRReviewSummary) -> some View {
        let style = reviewStateStyle(r.state)
        HStack(spacing: 2) {
            Image(systemName: style.icon)
                .foregroundStyle(style.color)
            Text(r.isFromViewer ? "you" : r.author)
                .foregroundStyle(.secondary)
        }
        .font(.caption2)
        .help("\(r.isFromViewer ? "You" : "@\(r.author)") \(style.label)")
    }

    @ViewBuilder
    private var humanReviewsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { reviewsExpanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: reviewsExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("Reviews & Comments")
                            .font(.subheadline.bold())
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if !reviewsExpanded {
                    // Compact glance: one verdict chip per reviewer plus a
                    // comment count, so the user sees who reviewed and how
                    // without expanding (and without pushing actions down).
                    ForEach(reviewerSummaries) { reviewerChip($0) }
                    if !pr.issueComments.isEmpty {
                        HStack(spacing: 2) {
                            Image(systemName: "text.bubble")
                            Text("\(pr.issueComments.count)")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("\(pr.issueComments.count) comment\(pr.issueComments.count == 1 ? "" : "s")")
                    }
                }

                Spacer(minLength: 4)
            }

            if reviewsExpanded {
                ForEach(activityEntries) { entry in
                    activityRow(entry)
                }
            }
        }
    }

    @ViewBuilder
    private func activityRow(_ entry: ActivityEntry) -> some View {
        switch entry.kind {
        case .review(let r):
            let style = reviewStateStyle(r.state)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: style.icon)
                        .foregroundStyle(style.color)
                        .font(.caption)
                    Text(r.isFromViewer ? "You" : "@\(r.author)")
                        .font(.caption.bold())
                    Text(style.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let d = r.submittedAt {
                        Text("· \(d.formatted(.relative(presentation: .named)))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if !r.body.isEmpty {
                    MarkdownText(raw: r.body)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(style.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        case .comment(let c):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "text.bubble")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text(c.isFromViewer ? "You" : "@\(c.author)")
                        .font(.caption.bold())
                    Text("commented")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let d = c.createdAt {
                        Text("· \(d.formatted(.relative(presentation: .named)))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                MarkdownText(raw: c.body)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
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
            // Reads `liveProgress` from inside its own `View` struct so
            // SwiftUI's @Observable dependency tracking scopes the
            // high-frequency progress updates to *that* subtree. Reading
            // it here (in PRDetailView.body) would make every ~100ms-1s
            // progress event invalidate the whole detail view and force a
            // full re-layout of the expensive diff section. Same spirit as
            // keeping the action bar out of the scrolling container.
            LiveReviewProgressView(nodeId: pr.nodeId)
            if let prior = priorReview {
                priorReviewBanner(prior)
                completedReviewSection(prior.aggregated)
            }
        }
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
                let lineCount = hunks.reduce(0) { $0 + $1.lines.count }
                if lineCount > Self.maxInlineDiffLines && !forceRenderLargeDiff {
                    largeDiffPlaceholder(
                        lineCount: lineCount,
                        fileCount: Set(hunks.map(\.filePath)).count
                    )
                } else {
                    DiffView(
                        hunks: hunks,
                        annotations: review?.annotations ?? [],
                        subpaths: subpathsFromReview(),
                        focusedKey: $focusedDiffKey
                    )
                }
            }
        }
    }

    /// Shown in place of a multi-thousand-line inline diff. Rendering one
    /// inline makes the popover scroll unusably slow (DiffView builds every
    /// line eagerly and the CALayer tree churns during scroll), so we link
    /// out to GitHub's files view by default and let the user opt in.
    @ViewBuilder
    private func largeDiffPlaceholder(lineCount: Int, fileCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.secondary)
                Text("Large diff — \(lineCount) lines across \(fileCount) file\(fileCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Rendering this inline makes the popover sluggish, so it's collapsed by default.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.open(pr.url.appendingPathComponent("files"))
                } label: {
                    Label("View diff on GitHub", systemImage: "arrow.up.forward.square")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("Render anyway") { forceRenderLargeDiff = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
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

    /// Wraps `actionsSection` with a top divider + opaque background so
    /// it works as a `Section { } header:` that pins on scroll. The
    /// background prevents scrolled content from bleeding through; the
    /// `Divider` mirrors the inline divider the section had before
    /// pinning so it doesn't visually fuse with the AI section above.
    @ViewBuilder
    /// The review actions, framed as a subtle inset card so they stand
    /// out from the surrounding sections without a full-width background
    /// band. No longer a pinned/sticky header — the reviews section
    /// collapses by default, so the actions already sit high in the view,
    /// and inline placement sidesteps the "scrolled content bleeds through
    /// a translucent pinned header" problem the band was there to solve.
    private var actionsCard: some View {
        actionsSection
            .padding(12)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
    }

    // MARK: - merge actions (own PRs)

    /// Persist the last merge method chosen per-repo so the split button's
    /// primary action defaults to "what you did last time" here. Shares the
    /// `lastMergeMethod.<owner>/<repo>` key with `PRRowView` so the detail
    /// view and the inbox row stay in sync.
    private var mergeDefaultsKey: String { "lastMergeMethod.\(pr.nameWithOwner)" }

    private var defaultMergeMethod: MergeMethod {
        if let raw = UserDefaults.standard.string(forKey: mergeDefaultsKey),
           let stored = MergeMethod(rawValue: raw),
           pr.allowedMergeMethods.contains(stored) {
            return stored
        }
        return pr.preferredMergeMethod ?? .squash
    }

    private func rememberMergeMethod(_ m: MergeMethod) {
        UserDefaults.standard.set(m.rawValue, forKey: mergeDefaultsKey)
    }

    /// Effective "skip merge confirmation" for this PR's repo: per-repo
    /// override wins, else the global setting.
    private var skipMergeConfirmation: Bool {
        repoConfigs.resolve(owner: pr.owner, repo: pr.repo)
            .skipMergeConfirmation ?? skipMergeConfirmationGlobal
    }

    /// Either merge immediately (confirmation disabled) or stage the
    /// confirmation dialog. Single funnel so both the primary action and
    /// the dropdown alternatives honour the setting.
    private func requestMerge(_ method: MergeMethod) {
        if skipMergeConfirmation {
            rememberMergeMethod(method)
            actionQueue.enqueue(pr, kind: .merge(method: method))
        } else {
            pendingMergeMethod = method
            showMergeConfirm = true
        }
    }

    /// Merge surface for PRs the viewer authored — the analogue of
    /// `actionsCard` for the review path. Shows merge-readiness status plus
    /// the right action: immediate merge when ready, enable-auto-merge when
    /// blocked but the repo allows it, disable-auto-merge when one is queued.
    private var mergeCard: some View {
        mergeSection
            .padding(12)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
    }

    @ViewBuilder
    private var mergeSection: some View {
        let isBusy = actionQueue.isBusy(pr.nodeId)
        VStack(alignment: .leading, spacing: 8) {
            mergeStatusLine

            HStack(spacing: 8) {
                if pr.isReadyToMerge {
                    mergeSplitButton(disabled: isBusy)
                } else if pr.autoMergeAllowed && !pr.hasAutoMerge {
                    enableAutoMergeButton(disabled: isBusy)
                }

                if pr.hasAutoMerge {
                    Button(role: .destructive) {
                        actionQueue.enqueue(pr, kind: .disableAutoMerge)
                    } label: {
                        Label("Disable auto-merge", systemImage: "clock.badge.xmark")
                            .font(.callout)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isBusy)
                }

                if isBusy {
                    ProgressView().controlSize(.small)
                }

                Spacer()

                Button {
                    NSWorkspace.shared.open(pr.url)
                } label: {
                    Label("Open", systemImage: "safari")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Open this PR on GitHub")
            }

            // For `.both` PRs the review `actionsCard` already renders the
            // shared failure banner (it reads the same per-PR action state),
            // so only show ours when this is the sole action surface.
            if !showsReviewActions, case .failed(let msg) = actionQueue.state(for: pr.nodeId) {
                actionFailedBanner(message: msg)
            }
        }
    }

    @ViewBuilder
    private var mergeStatusLine: some View {
        if pr.hasAutoMerge {
            Label {
                let method = pr.autoMergeMethod.map { " (\($0.shortDisplayName))" } ?? ""
                let who = pr.autoMergeEnabledBy.map { " by @\($0)" } ?? ""
                Text("Auto-merge\(method) enabled\(who) — merges automatically once checks pass")
            } icon: {
                Image(systemName: "clock.arrow.2.circlepath").foregroundStyle(.blue)
            }
            .font(.caption)
        } else if let reason = pr.mergeBlockReason {
            Label { Text(reason) } icon: {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            Label { Text("Ready to merge") } icon: {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            }
            .font(.caption)
        }
    }

    /// Green split button — primary fires the default method (confirmed via
    /// dialog), the chevron menu offers the other repo-allowed methods.
    @ViewBuilder
    private func mergeSplitButton(disabled: Bool) -> some View {
        let primary = defaultMergeMethod
        let alternatives = MergeMethod.allCases.filter {
            pr.allowedMergeMethods.contains($0) && $0 != primary
        }
        Menu {
            ForEach(alternatives, id: \.rawValue) { method in
                Button {
                    requestMerge(method)
                } label: {
                    Label(method.displayName, systemImage: "arrow.triangle.merge")
                }
            }
        } label: {
            Label(primary.shortDisplayName, systemImage: "arrow.triangle.merge")
                .labelStyle(.titleAndIcon)
                .font(.callout.weight(.semibold))
        } primaryAction: {
            requestMerge(primary)
        }
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .tint(.green)
        .controlSize(.small)
        .fixedSize()
        .disabled(disabled)
        .help("\(primary.displayName) #\(pr.numberString) — click chevron for alternatives")
    }

    /// Enable-auto-merge split button. No confirmation — it's reversible and
    /// nothing merges until checks pass. Primary uses the default method; the
    /// chevron offers the other allowed methods.
    @ViewBuilder
    private func enableAutoMergeButton(disabled: Bool) -> some View {
        let primary = defaultMergeMethod
        let alternatives = MergeMethod.allCases.filter {
            pr.allowedMergeMethods.contains($0) && $0 != primary
        }
        Menu {
            ForEach(alternatives, id: \.rawValue) { method in
                Button {
                    rememberMergeMethod(method)
                    actionQueue.enqueue(pr, kind: .enableAutoMerge(method: method))
                } label: {
                    Label("Auto-merge · \(method.shortDisplayName)", systemImage: "clock.arrow.2.circlepath")
                }
            }
        } label: {
            Label("Auto-merge · \(primary.shortDisplayName)", systemImage: "clock.arrow.2.circlepath")
                .font(.callout)
        } primaryAction: {
            rememberMergeMethod(primary)
            actionQueue.enqueue(pr, kind: .enableAutoMerge(method: primary))
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .disabled(disabled)
        .help("Queue a \(primary.displayName.lowercased()) to run once required checks and reviews pass")
    }

    /// Action surface, sits directly under the AI verdict + summary +
    /// annotations so verdict and post controls are co-located. The
    /// primary button is driven by the AI's verdict (or "Approve" if
    /// the AI abstained / hasn't run yet); secondary actions live in
    /// a dropdown so the user can override.
    @ViewBuilder
    private var actionsSection: some View {
        let isPosting = actionQueue.isBusy(pr.nodeId)
        let aiVerdict = review?.verdict
        // For the action bar: `.comment` verdict ("approve with notes")
        // maps to a GitHub APPROVE review carrying the body. The neutral
        // `.comment` action is still reachable from the override menu.
        let primary: ReviewActionKind = aiVerdict.flatMap(reviewAction(for:)) ?? .approve
        let postable = postableInlineComments
        let primaryNeedsBody = (primary == .requestChanges)
        let primaryDisabled = isPosting || (primaryNeedsBody && bodyDraft.isEmpty)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                primaryActionButton(primary, disabled: primaryDisabled)

                Menu {
                    overrideActionItems(except: primary)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Post a different review action")
                .disabled(isPosting)

                if isPosting {
                    ProgressView().controlSize(.small)
                }

                Spacer()

                Button {
                    bodyExpanded.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: bodyExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                        Text(bodyExpanded ? "Hide body" : "Edit body")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }

            // What's about to be sent — shown inline so the user
            // doesn't have to expand the body editor to know whether
            // the AI summary is going along for the ride. Two
            // checkboxes: AI summary (body) and inline annotations
            // (line-anchored comments). Both default to the user's
            // global setting; both can be flipped per-PR right here.
            HStack(spacing: 14) {
                if let summary = review?.summaryMarkdown, !summary.isEmpty {
                    Toggle(isOn: Binding(
                        get: { includeAISummary },
                        set: { handleIncludeSummaryToggle($0) }
                    )) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Include AI summary as body")
                                .font(.caption)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .help("When on, the AI's `summary` text is sent as the body of the review. Per-PR override of the Settings → General default. Toggle off to send an empty (or hand-edited) body.")
                }

                if !postable.isEmpty {
                    Toggle(isOn: $includeInlineAnnotations) {
                        HStack(spacing: 4) {
                            Image(systemName: "text.bubble")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(postable.count) inline annotation\(postable.count == 1 ? "" : "s")")
                                .font(.caption)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .help("When on, each annotation becomes a line-anchored review comment in the same submission. Annotations targeting lines not in the PR's diff are skipped automatically.")
                }

                Spacer()
            }

            willPostPreview(primary: primary, postableCount: postable.count)

            if bodyExpanded {
                TextEditor(text: $bodyDraft)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 80, maxHeight: 200)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(.secondary.opacity(0.2))
                    )
                    .help("Body for the review. Pre-fills with the AI summary; edit freely.")

                HStack(spacing: 8) {
                    if !bodyDraft.isEmpty {
                        Button("Clear") {
                            bodyDraft = ""
                            bodyDraftSeededForSha = nil
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(isPosting)
                    }
                    if let summary = review?.summaryMarkdown, !summary.isEmpty, bodyDraft != summary {
                        Button("Reset to AI summary") {
                            bodyDraft = summary
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(isPosting)
                    }
                    Spacer()
                    Text("\(bodyDraft.count) chars")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if case .failed(let msg) = actionQueue.state(for: pr.nodeId) {
                actionFailedBanner(message: msg)
            } else if let err = poller.lastError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    /// Shown when the queued review post failed (gh/network error). The
    /// captured action is retained by `ActionQueue`, so Retry re-runs it
    /// verbatim without the user re-typing anything.
    @ViewBuilder
    private func actionFailedBanner(message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text("Posting failed")
                    .font(.caption.bold())
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Retry") { actionQueue.retry(pr.nodeId) }
                .buttonStyle(.borderless)
                .font(.caption)
            Button("Dismiss") { actionQueue.dismissFailure(pr.nodeId) }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }

    /// One-line summary of what the next click of the primary button
    /// will send to GitHub. Lists the GitHub event, body status, and
    /// inline-comment count so the user never has to expand the body
    /// editor to know what's about to be posted.
    @ViewBuilder
    private func willPostPreview(primary: ReviewActionKind, postableCount: Int) -> some View {
        let event: String = {
            switch primary {
            case .approve:        return "APPROVE"
            case .comment:        return "COMMENT"
            case .requestChanges: return "REQUEST_CHANGES"
            }
        }()
        let bodySummary: String = {
            if bodyDraft.isEmpty { return "no body" }
            let trimmed = bodyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            // 60-char clip is enough to recognise "this is the AI
            // summary" without taking a second line of UI.
            let preview = trimmed.replacingOccurrences(of: "\n", with: " ")
            return preview.count > 60
                ? "body: \"\(preview.prefix(60))…\""
                : "body: \"\(preview)\""
        }()
        let inlinePart: String = {
            guard includeInlineAnnotations, postableCount > 0 else { return "" }
            return " · \(postableCount) inline comment\(postableCount == 1 ? "" : "s")"
        }()
        Text("Will post: \(event) · \(bodySummary)\(inlinePart)")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(bodyDraft.isEmpty ? "Empty body" : bodyDraft)
    }

    @ViewBuilder
    private func primaryActionButton(_ kind: ReviewActionKind, disabled: Bool) -> some View {
        Button {
            postReview(kind: kind, includeInline: includeInlineAnnotations)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: actionButtonIcon(kind))
                Text(primaryActionLabel(kind))
            }
            .frame(minWidth: 140)
        }
        .buttonStyle(.borderedProminent)
        .tint(actionButtonTint(kind))
        .controlSize(.large)
        .disabled(disabled)
        .help(primaryActionHelp(kind))
        .keyboardShortcut(.defaultAction)
    }

    @ViewBuilder
    private func overrideActionItems(except primary: ReviewActionKind) -> some View {
        // Three GitHub review actions, plus the inline-comments toggle
        // mirrored in the menu so a user who hides the toolbar still
        // has access. Greyed-out items are kept clickable and just
        // rerun the same call so we don't over-engineer disabled state.
        let postable = postableInlineComments
        let isPosting = actionQueue.isBusy(pr.nodeId)

        if primary != .approve {
            Button {
                postReview(kind: .approve, includeInline: includeInlineAnnotations)
            } label: { Label("Approve", systemImage: "hand.thumbsup") }
                .disabled(isPosting)
        }
        if primary != .requestChanges {
            Button {
                postReview(kind: .requestChanges, includeInline: includeInlineAnnotations)
            } label: { Label("Request changes", systemImage: "hand.thumbsdown") }
                .disabled(isPosting || bodyDraft.isEmpty)
        }
        if primary != .comment {
            Button {
                postReview(kind: .comment, includeInline: includeInlineAnnotations)
            } label: { Label("Comment (neutral)", systemImage: "bubble.left") }
                .disabled(isPosting || bodyDraft.isEmpty)
        }
        if !postable.isEmpty {
            Divider()
            Toggle(isOn: $includeInlineAnnotations) {
                Text("Include \(postable.count) inline annotation\(postable.count == 1 ? "" : "s")")
            }
        }
    }

    private func actionButtonIcon(_ kind: ReviewActionKind) -> String {
        switch kind {
        case .approve:        return "hand.thumbsup"
        case .comment:        return "bubble.left"
        case .requestChanges: return "hand.thumbsdown"
        }
    }

    /// Label for the primary action button. When the AI's verdict is
    /// `.comment` ("approve with notes"), kind is `.approve` but the
    /// label is "Approve with notes" so the user knows their summary
    /// will travel with the approval.
    private func primaryActionLabel(_ kind: ReviewActionKind) -> String {
        let aiVerdict = review?.verdict
        switch kind {
        case .approve:
            return aiVerdict == .comment ? "Approve with notes" : "Approve"
        case .comment:        return "Comment"
        case .requestChanges: return "Request changes"
        }
    }

    private func actionButtonTint(_ kind: ReviewActionKind) -> Color {
        switch kind {
        case .approve:        return .green
        case .comment:        return .blue
        case .requestChanges: return .orange
        }
    }

    private func primaryActionHelp(_ kind: ReviewActionKind) -> String {
        switch kind {
        case .approve:
            return review?.verdict == .comment
                ? "Approve with the AI summary as the body and any inline annotations."
                : "Approve this PR."
        case .comment:        return "Post a neutral Comment review (no approval signal)."
        case .requestChanges: return "Request changes — body required."
        }
    }

    /// Annotations that have a corresponding line on the new side of
    /// the PR's diff — i.e. lines GitHub will accept inline comments
    /// for. Anything outside this set is dropped silently when posting,
    /// so the toolbar's count matches what actually goes through.
    private var postableInlineComments: [GHClient.InlineComment] {
        guard let annotations = review?.annotations, !annotations.isEmpty else { return [] }
        guard case .loaded(let hunks) = diffStore.status(for: pr) else { return [] }
        return Self.inlineComments(from: annotations, hunks: hunks)
    }

    /// Map annotations whose `(path, lineEnd)` lands on an added or
    /// context line in the new file to a GHClient.InlineComment. Body
    /// is the annotation's body (full text); the title isn't included
    /// because GitHub renders the comment as plain Markdown.
    static func inlineComments(
        from annotations: [DiffAnnotation],
        hunks: [Hunk]
    ) -> [GHClient.InlineComment] {
        // Build per-path map of valid new-file line numbers.
        var validByPath: [String: Set<Int>] = [:]
        for h in hunks {
            var newLine = h.newStart
            var valid: Set<Int> = []
            for line in h.lines {
                switch line {
                case .added, .context:
                    valid.insert(newLine)
                    newLine += 1
                case .removed:
                    break
                }
            }
            validByPath[h.filePath, default: []].formUnion(valid)
        }
        return annotations.compactMap { ann in
            guard let valid = validByPath[ann.path] else { return nil }
            guard valid.contains(ann.lineEnd) else { return nil }
            let startLine = ann.lineStart < ann.lineEnd && valid.contains(ann.lineStart)
                ? ann.lineStart : nil
            let header: String = {
                if let t = ann.title, !t.isEmpty { return "**\(t)**\n\n" }
                return ""
            }()
            return GHClient.InlineComment(
                path: ann.path,
                line: ann.lineEnd,
                startLine: startLine,
                body: header + ann.body
            )
        }
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

    private func postReview(kind: ReviewActionKind, includeInline: Bool) {
        let comments = includeInline ? postableInlineComments : []
        actionQueue.enqueue(
            pr,
            kind: .review(kind: kind, body: bodyDraft, comments: comments),
            source: .manual
        )
        bodyDraft = ""
        bodyDraftSeededForSha = nil
        onPostedAction()
    }

    /// Map AI verdict → the GitHub review action the primary button
    /// should fire. `.comment` ("approve with notes") fires APPROVE
    /// with a body — what most "I approve, with these observations"
    /// reviews actually want. The neutral GitHub Comment review is
    /// reachable via the override menu.
    private func reviewAction(for verdict: ReviewVerdict) -> ReviewActionKind? {
        switch verdict {
        case .approve:        return .approve
        case .comment:        return .approve
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
        case .comment:        return ("Approve with notes", .blue)
        case .requestChanges: return ("Request changes", .red)
        case .abstain:        return ("Abstain", .gray)
        }
    }
}

/// Live AI-review progress chip (tool count / cost / running tool).
///
/// Deliberately a standalone `View` rather than a `@ViewBuilder` method on
/// `PRDetailView`: helper methods are inlined into the parent's `body`
/// observation scope, so reading the high-frequency `liveProgress`
/// dictionary there would re-evaluate the entire detail view — and
/// re-layout the expensive diff section — on every progress event (several
/// per second on a large diff). Owning the `liveProgress` read here scopes
/// the invalidation to this small subtree.
private struct LiveReviewProgressView: View {
    @Environment(ReviewQueueWorker.self) private var queue
    let nodeId: String

    var body: some View {
        if let progress = queue.liveProgress[nodeId] {
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
    }
}
