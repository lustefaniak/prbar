import SwiftUI

struct PRRowView: View {
    let pr: InboxPR
    let isRefreshing: Bool
    let onRefresh: () -> Void

    @State private var isHovering = false

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
            if isRefreshing {
                ProgressView().controlSize(.small)
            } else if isHovering {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("Refresh this PR")
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(tooltip)
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
