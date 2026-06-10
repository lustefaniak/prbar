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
    let onRefreshPR: (InboxPR) -> Void
    let onMergePR: (InboxPR, MergeMethod) -> Void
    let onSelect: (InboxPR) -> Void

    @Environment(DiffStore.self) private var diffStore
    @Environment(ActionQueue.self) private var actionQueue
    @Environment(RepoConfigStore.self) private var repoConfigs
    @AppStorage("skipMergeConfirmation") private var skipMergeConfirmationGlobal = false

    /// Effective "skip merge confirmation" for a PR: per-repo override
    /// wins over the global setting.
    private func skipMergeConfirmation(for pr: InboxPR) -> Bool {
        repoConfigs.resolve(owner: pr.owner, repo: pr.repo)
            .skipMergeConfirmation ?? skipMergeConfirmationGlobal
    }

    /// Cap how many rows we eagerly warm the diff cache for. The list
    /// itself scrolls and shows every PR; this is just a courtesy
    /// prefetch for the rows likely to be visible without scrolling.
    private let prefetchLimit = 12

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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(prs) { pr in
                            PRRowView(
                                pr: pr,
                                isRefreshing: refreshingPRs.contains(pr.nodeId),
                                actionState: actionQueue.state(for: pr.nodeId),
                                onRefresh: { onRefreshPR(pr) },
                                onMerge: { method in onMergePR(pr, method) },
                                onRetryAction: { actionQueue.retry(pr.nodeId) },
                                onDismissAction: { actionQueue.dismissFailure(pr.nodeId) },
                                skipMergeConfirmation: skipMergeConfirmation(for: pr)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(pr) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                // Warm the diff cache for the first few rows so clicking
                // a PR near the top typically lands on a cached diff.
                .task(id: prs.prefix(prefetchLimit).map(\.headSha).joined(separator: "|")) {
                    for pr in prs.prefix(prefetchLimit) {
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
