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

    @Environment(DiffStore.self) private var diffStore

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
                // Warm the diff cache for visible rows so clicking a PR
                // typically lands on a cached diff. Each call is a no-op
                // when the (prNodeId, headSha) is already loaded or in
                // flight, so this is safe to call on every list re-render.
                Color.clear.frame(height: 0)
                    .task(id: prs.map(\.headSha).joined(separator: "|")) {
                        for pr in prs.prefix(visibleLimit) {
                            diffStore.ensureLoaded(for: pr)
                        }
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
