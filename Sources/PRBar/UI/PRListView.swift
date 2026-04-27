import SwiftUI

/// Shared list-of-PRs view used by both MyPRsView and InboxView. Handles
/// empty / fetching / errored states uniformly so the two tabs only differ
/// in filtering + empty-state copy.
struct PRListView: View {
    let prs: [InboxPR]
    let emptyText: String
    let isFetching: Bool
    let lastError: String?
    let refreshingPRs: Set<String>
    let mergingPRs: Set<String>
    let onRefreshPR: (InboxPR) -> Void
    let onMergePR: (InboxPR, MergeMethod) -> Void
    let onSelect: (InboxPR) -> Void

    private let visibleLimit = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = lastError, prs.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(4)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } else if prs.isEmpty {
                Text(isFetching ? "Fetching…" : emptyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(prs.prefix(visibleLimit)) { pr in
                    PRRowView(
                        pr: pr,
                        isRefreshing: refreshingPRs.contains(pr.nodeId),
                        isMerging: mergingPRs.contains(pr.nodeId),
                        onRefresh: { onRefreshPR(pr) },
                        onMerge: { method in onMergePR(pr, method) }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(pr) }
                }
                if prs.count > visibleLimit {
                    Text("…and \(prs.count - visibleLimit) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = lastError {
                    Text("Last fetch failed: \(error)")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        }
    }
}
