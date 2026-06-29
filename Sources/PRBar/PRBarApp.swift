import SwiftUI
import AppKit

/// Cross-process signal names. PRBar enforces a single instance, so a
/// second launch hands off to the running one via these.
enum PRBarActivation {
    /// Posted by a second launch (which then exits) to ask the live
    /// instance to bring a usable window to front — the recovery path
    /// when the menu-bar icon is hidden and the app is otherwise
    /// unreachable. Observed in `AppDelegate`.
    static let surface = Notification.Name("dev.lustefaniak.prbar.surface")
}

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
            // The running instance can be unreachable when its menu-bar
            // icon got hidden by menu-bar overflow (notch / crowded bar) —
            // PRBar has no Dock icon, so re-launching from /Applications is
            // the user's only recovery gesture. Ask the live instance to
            // surface a usable window before we bow out, instead of leaving
            // the user with a process they can't see or interact with.
            DistributedNotificationCenter.default().postNotificationName(
                PRBarActivation.surface,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
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
                .environment(delegate.actionQueue)
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
                    .environment(delegate.actionQueue)
                    .environment(delegate.diffStore)
                    .environment(delegate.failureLogs)
                    .environment(delegate.repoConfigs)
                    .environment(delegate.readiness)
                    .environment(delegate.actionLog)
                    .environment(delegate.reviewLog)
            } else {
                SelfClosingWindow()
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
                    .environment(delegate.actionQueue)
                    .environment(delegate.diffStore)
                    .environment(delegate.repoConfigs)
                    .environment(delegate.actionLog)
                    .environment(delegate.reviewLog)
                    .environment(delegate.failureLogs)
                    .environment(delegate.notifier)
                    .environment(delegate.readiness)
                    .modelContainer(delegate.reviewLog.container)
            } else {
                SelfClosingWindow()
            }
        }
        .defaultSize(width: 1100, height: 800)
    }
}

/// Placeholder for a `WindowGroup` window that SwiftUI restored with a
/// `nil` value. Scene restoration re-opens `WindowGroup(for:)` windows on
/// relaunch when the system "Close windows when quitting an application"
/// setting is off (`NSQuitAlwaysKeepsWindows`), but the persisted value
/// can come back empty — which previously left a dead "No PR selected"
/// window the user couldn't escape (PRBar is a menu-bar agent with no
/// Dock icon, so there's no other handle on the window). Close it on
/// appear instead of stranding it. Legitimate opens always pass a
/// non-nil value via `openWindow(id:value:)`, so they never reach here.
private struct SelfClosingWindow: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear { dismiss() }
    }
}
