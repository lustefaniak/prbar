import SwiftUI
import AppKit

@main
struct PRBarApp: App {
    @State private var poller: PRPoller
    @State private var notifier: Notifier
    @State private var queue: ReviewQueueWorker
    @State private var diffStore: DiffStore
    @State private var repoConfigs: RepoConfigStore

    init() {
        // Single-instance: if another PRBar is already running, bow out
        // immediately so we don't end up with two menu-bar icons + two
        // pollers fighting over `inbox-snapshot.json` / `reviews.json`.
        // Compare bundle ID against runningApplications, exclude
        // ourselves by PID. The existing instance is left alone; we
        // exit(0) before SwiftUI builds any scenes.
        Self.enforceSingleInstance()

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

    private static func enforceSingleInstance() {
        // XCTest hosts the app inside a runner process; an early exit(0)
        // here makes xcodebuild think the test bundle never bootstrapped.
        // Detect the test session by the XCTest bundle's env var and skip.
        if ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil {
            return
        }
        if NSClassFromString("XCTestCase") != nil {
            return
        }
        let myBundleID = Bundle.main.bundleIdentifier ?? "dev.lustefaniak.prbar"
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: myBundleID)
            .filter { $0.processIdentifier != myPID }
        if !others.isEmpty {
            others.first?.activate(options: [])
            exit(0)
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
