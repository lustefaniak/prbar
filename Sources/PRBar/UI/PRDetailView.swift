import SwiftUI
import AppKit

/// Detail view for one PR. Shows the AI review (if any) plus action
/// buttons. Replaces the popover's tab list when a row is selected.
struct PRDetailView: View {
    let pr: InboxPR
    let onBack: () -> Void

    @Environment(PRPoller.self) private var poller
    @Environment(ReviewQueueWorker.self) private var queue

    @State private var bodyDraft: String = ""
    @State private var showActionPicker: Bool = false

    private var review: AggregatedReview? {
        if case .completed(let agg) = queue.reviews[pr.nodeId]?.status {
            return agg
        }
        return nil
    }

    private var reviewStatus: ReviewState.Status? {
        queue.reviews[pr.nodeId]?.status
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            navHeader

            Divider()

            prHeader

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    aiSection
                    Divider()
                    actionsSection
                }
            }
        }
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
            Text("\(pr.nameWithOwner) #\(pr.number)")
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
                        .foregroundStyle(.secondary)
                        .help("Total cost")
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
                Text("\(agg.annotations.count) annotation\(agg.annotations.count == 1 ? "" : "s") (rendered with diff in Phase 3)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
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
