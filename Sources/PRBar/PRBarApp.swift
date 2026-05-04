import SwiftUI
import AppKit

@main
struct PRBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // Single-instance: bow out if another PRBar is already running.
        // Done before SwiftUI builds any scenes / before the AppDelegate
        // creates services. XCTest hosts the app so we exempt it.
        Self.enforceSingleInstance()
    }

    private static func enforceSingleInstance() {
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
        // The menu bar item + popover are managed by AppDelegate via
        // NSStatusItem — see that file for the left/right-click split.
        // SwiftUI just provides the Settings scene; opening it goes
        // through Cmd+, or the right-click menu's "Settings…" entry.
        Settings {
            SettingsRoot()
                .environment(delegate.poller)
                .environment(delegate.notifier)
                .environment(delegate.queue)
                .environment(delegate.diffStore)
                .environment(delegate.failureLogs)
                .environment(delegate.repoConfigs)
                .environment(delegate.readiness)
                .environment(delegate.actionLog)
                .environment(delegate.reviewLog)
                .modelContainer(delegate.reviewLog.container)
        }

        // Standalone full-size detail window. Opened from the popover's
        // PRDetailView via `openWindow(id: PRDetailWindowID.id, value:
        // pr.nodeId)`. Keyed by `String` so each PR gets its own window
        // (multiple can be open at once); resolved against
        // `PRPoller.prs` so the window stays live across polls.
        WindowGroup(id: PRDetailWindowID.id, for: String.self) { $nodeId in
            if let id = nodeId {
                PRDetailWindowView(nodeId: id)
                    .environment(delegate.poller)
                    .environment(delegate.notifier)
                    .environment(delegate.queue)
                    .environment(delegate.diffStore)
                    .environment(delegate.failureLogs)
                    .environment(delegate.repoConfigs)
                    .environment(delegate.readiness)
                    .environment(delegate.actionLog)
                    .environment(delegate.reviewLog)
            } else {
                Text("No PR selected")
                    .frame(minWidth: 400, minHeight: 200)
            }
        }
        .defaultSize(width: 1100, height: 800)

        // Historical-review window: opened from Settings → Review
        // History to look at a cached AggregatedReview in the same
        // detail layout (verdict + summary + annotations + diff). Keyed
        // by the ReviewLogEntry's UUID so each row gets its own window;
        // the view re-fetches the PR fresh from gh to surface live
        // diff/CI/body when the PR still exists, and falls back to the
        // cached review only when it doesn't.
        WindowGroup(id: HistoricalReviewWindowID.id, for: UUID.self) { $logId in
            if let id = logId {
                HistoricalReviewWindowView(logEntryId: id)
                    .environment(delegate.poller)
                    .environment(delegate.queue)
                    .environment(delegate.diffStore)
                    .environment(delegate.repoConfigs)
                    .environment(delegate.actionLog)
                    .environment(delegate.reviewLog)
                    .environment(delegate.failureLogs)
                    .environment(delegate.notifier)
                    .environment(delegate.readiness)
                    .modelContainer(delegate.reviewLog.container)
            } else {
                Text("No review selected")
                    .frame(minWidth: 400, minHeight: 200)
            }
        }
        .defaultSize(width: 1100, height: 800)
    }
}
