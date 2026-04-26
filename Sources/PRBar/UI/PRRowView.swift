import SwiftUI
import AppKit

struct PRRowView: View {
    let pr: InboxPR
    let isRefreshing: Bool
    let isMerging: Bool
    let onRefresh: () -> Void
    let onMerge: (MergeMethod) -> Void

    @State private var isHovering = false
    @State private var showMergeConfirm = false
    @State private var pendingMergeMethod: MergeMethod = .squash

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            roleBadge
            VStack(alignment: .leading, spacing: 1) {
                Text(pr.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text("\(pr.nameWithOwner) #\(pr.number)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if pr.isDraft {
                        Text("draft")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    rollupBadge
                    reviewBadge
                }
            }
            Spacer()
            trailingControl
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(tooltip)
        .confirmationDialog(
            "\(pendingMergeMethod.displayName) #\(pr.number)?",
            isPresented: $showMergeConfirm,
            titleVisibility: .visible
        ) {
            Button(pendingMergeMethod.displayName, role: .destructive) {
                onMerge(pendingMergeMethod)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(pr.title)\n\(pr.nameWithOwner) → \(pr.baseRef)")
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if isMerging {
            ProgressView()
                .controlSize(.small)
                .help("Merging…")
        } else if isRefreshing {
            ProgressView()
                .controlSize(.small)
                .help("Refreshing…")
        } else if isHovering {
            Menu {
                Button {
                    NSWorkspace.shared.open(pr.url)
                } label: {
                    Label("Open in browser", systemImage: "safari")
                }
                Button {
                    onRefresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Divider()
                Button {
                    pendingMergeMethod = .squash
                    showMergeConfirm = true
                } label: {
                    Label("Squash and merge", systemImage: "arrow.triangle.merge")
                }
                Button {
                    pendingMergeMethod = .merge
                    showMergeConfirm = true
                } label: {
                    Label("Create merge commit", systemImage: "arrow.triangle.merge")
                }
                Button {
                    pendingMergeMethod = .rebase
                    showMergeConfirm = true
                } label: {
                    Label("Rebase and merge", systemImage: "arrow.triangle.merge")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Actions")
        }
    }

    private var tooltip: String {
        var parts = ["\(pr.nameWithOwner) #\(pr.number) — \(pr.title)"]
        parts.append("mergeable: \(pr.mergeStateStatus)")
        if let dec = pr.reviewDecision { parts.append("review: \(dec)") }
        parts.append("author: @\(pr.author)")
        return parts.joined(separator: "\n")
    }

    @ViewBuilder
    private var roleBadge: some View {
        switch pr.role {
        case .authored:
            Image(systemName: "person.fill")
                .foregroundStyle(.blue)
                .font(.caption)
        case .reviewRequested:
            Image(systemName: "eye.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        case .both:
            Image(systemName: "person.crop.circle.badge.checkmark")
                .foregroundStyle(.purple)
                .font(.caption)
        case .other:
            Image(systemName: "circle.dotted")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var rollupBadge: some View {
        switch pr.checkRollupState {
        case "SUCCESS":
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.caption2)
        case "FAILURE", "ERROR":
            Image(systemName: "xmark.seal.fill")
                .foregroundStyle(.red)
                .font(.caption2)
        case "PENDING", "EXPECTED":
            Image(systemName: "circle.dotted")
                .foregroundStyle(.yellow)
                .font(.caption2)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var reviewBadge: some View {
        switch pr.reviewDecision {
        case "APPROVED":
            Image(systemName: "hand.thumbsup.fill")
                .foregroundStyle(.green)
                .font(.caption2)
        case "CHANGES_REQUESTED":
            Image(systemName: "hand.thumbsdown.fill")
                .foregroundStyle(.red)
                .font(.caption2)
        case "REVIEW_REQUIRED":
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
                .font(.caption2)
        default:
            EmptyView()
        }
    }
}
