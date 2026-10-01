import SwiftUI

struct MyPRsView: View {
    @Environment(InboxModel.self) private var poller
    @Environment(ActionQueue.self) private var actionQueue
    @AppStorage(MyDraftHandling.storageKey) private var draftHandlingRaw =
        MyDraftHandling.default.rawValue
    @AppStorage(MyPRsScope.storageKey) private var scopeRaw = MyPRsScope.default.rawValue
    @AppStorage("badgeShowReadyToMerge") private var badgeReadyToMerge = true
    @AppStorage("badgeShowCIFailed")     private var badgeCIFailed     = true
    let onSelect: (InboxPR) -> Void

    private var draftHandling: MyDraftHandling {
        MyDraftHandling(rawValue: draftHandlingRaw) ?? .default
    }

    private var scope: MyPRsScope {
        MyPRsScope(rawValue: scopeRaw) ?? .default
    }

    private var myPRs: [InboxPR] {
        MyPRsScope.visibleAuthored(
            from: poller.prs,
            draftHandling: draftHandling,
            scope: scope,
            badgeReadyToMerge: badgeReadyToMerge,
            badgeCIFailed: badgeCIFailed
        )
        .sorted(by: Self.priority)
    }

    private var hasAuthoredPRs: Bool {
        poller.prs.contains { $0.role == .authored || $0.role == .both }
    }

    /// When the "Show" scope narrows an otherwise-non-empty authored set down
    /// to nothing, name the active filter — "No PRs you authored" would be
    /// wrong and leave the user wondering where their PRs went.
    private var emptyText: String {
        if scope != .all, hasAuthoredPRs {
            return "No PRs match the \u{201C}\(scope.pickerLabel)\u{201D} filter."
        }
        return "No PRs you authored."
    }

    var body: some View {
        PRListView(
            prs: myPRs,
            emptyText: emptyText,
            isFetching: poller.isFetching,
            lastError: poller.lastError,
            refreshingPRs: poller.refreshingPRs,
            onRefreshPR: { poller.refreshPR($0) },
            onMergePR: { pr, method in actionQueue.enqueue(pr, kind: .merge(method: method)) },
            onSelect: onSelect
        )
    }

    /// Sort order is defined by `MyPRsCategory`'s case declaration order
    /// (ready-to-merge first, drafts last) via its synthesized `Comparable`.
    private static func priority(_ a: InboxPR, _ b: InboxPR) -> Bool {
        MyPRsCategory.of(a) < MyPRsCategory.of(b)
    }
}
