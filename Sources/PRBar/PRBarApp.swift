import SwiftUI

@main
struct PRBarApp: App {
    @State private var poller: PRPoller
    @State private var notifier: Notifier
    @State private var queue: ReviewQueueWorker
    @State private var diffStore: DiffStore
    @State private var repoConfigs: RepoConfigStore

    init() {
        let n = Notifier()
        let p = PRPoller.live()
        let q = ReviewQueueWorker.live()
        let d = DiffStore.sharing(q)
        let rc = RepoConfigStore()
        // User configs win over built-ins via the snapshotted resolver.
        q.configResolver = rc.makeResolver()
        // Refresh the resolver after every persisted edit so live changes
        // affect the next review without a restart.
        rc.onChange = { [weak q, weak rc] in
            guard let q, let rc else { return }
            q.configResolver = rc.makeResolver()
        }
        p.notifier = n
        _notifier = State(initialValue: n)
        _poller = State(initialValue: p)
        _queue = State(initialValue: q)
        _diffStore = State(initialValue: d)
        _repoConfigs = State(initialValue: rc)
        Task { await n.requestAuthorization() }
        // Best-effort cleanup of leaked worktrees from a previous crash.
        if let mgr = q.checkoutManager {
            Task { await mgr.sweepStaleWorktrees() }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(poller)
                .environment(notifier)
                .environment(queue)
                .environment(diffStore)
                .environment(repoConfigs)
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsRoot()
                .environment(poller)
                .environment(notifier)
                .environment(queue)
                .environment(diffStore)
                .environment(repoConfigs)
        }
    }
}
