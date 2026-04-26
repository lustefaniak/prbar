import SwiftUI
import AppKit

/// Detail view for one PR. Shows the AI review (if any) plus action
/// buttons. Replaces the popover's tab list when a row is selected.
struct PRDetailView: View {
    let pr: InboxPR
    let onBack: () -> Void

    @Environment(PRPoller.self) private var poller
    @Environment(ReviewQueueWorker.self) private var queue
    @Environment(DiffStore.self) private var diffStore

    @State private var bodyDraft: String = ""
    @State private var showActionPicker: Bool = false

    /// Set when the user clicks an annotation row → drives scroll +
    /// expand-bubble in the diff. Cleared after a short delay so the
    /// same annotation can be re-clicked to re-jump.
    @State private var focusedDiffKey: String? = nil

    private var review: AggregatedReview? {
        if case .completed(let agg) = queue.reviews[pr.nodeId]?.status {
            return agg
        }
        return nil
    }

    private var reviewStatus: ReviewState.Status? {
        queue.reviews[pr.nodeId]?.status
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

    @ViewBuilder
    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("AI Review")
                    .font(.subheadline.bold())
                Spacer()
                Button {
                    queue.enqueue(pr, force: true)
                } label: {
                    Label("Re-run", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled({
                    if case .running = reviewStatus { return true }
                    if case .queued  = reviewStatus { return true }
                    return false
                }())
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
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Queued").font(.caption).foregroundStyle(.secondary)
                }

            case .running:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reviewing…").font(.caption).foregroundStyle(.secondary)
                }

            case .failed(let msg):
                Text("Review failed: \(msg)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(4)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

            case .completed(let agg):
                completedReviewSection(agg)
            }
        }
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
                verdictBadge(agg.verdict)
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
            Text(agg.summaryMarkdown)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(20)
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
            TextEditor(text: $bodyDraft)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 60, maxHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(.secondary.opacity(0.2))
                )
                .help("Optional body for Approve/Comment/Request changes.")

            HStack(spacing: 6) {
                let isPosting = poller.postingReviewPRs.contains(pr.nodeId)

                Button {
                    poller.postReview(pr, kind: .approve, body: bodyDraft)
                    bodyDraft = ""
                } label: {
                    Label("Approve", systemImage: "hand.thumbsup")
                }
                .disabled(isPosting)

                Button {
                    poller.postReview(pr, kind: .comment, body: bodyDraft)
                    bodyDraft = ""
                } label: {
                    Label("Comment", systemImage: "bubble.left")
                }
                .disabled(isPosting || bodyDraft.isEmpty)
                .help("Comment requires a body.")

                Button {
                    poller.postReview(pr, kind: .requestChanges, body: bodyDraft)
                    bodyDraft = ""
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

    @ViewBuilder
    private func verdictBadge(_ verdict: ReviewVerdict) -> some View {
        let (label, color) = verdictAppearance(verdict)
        Text(label)
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color, in: Capsule())
    }

    private func verdictAppearance(_ v: ReviewVerdict) -> (String, Color) {
        switch v {
        case .approve:        return ("APPROVE", .green)
        case .comment:        return ("COMMENT", .blue)
        case .requestChanges: return ("CHANGES", .red)
        case .abstain:        return ("ABSTAIN", .gray)
        }
    }
}
