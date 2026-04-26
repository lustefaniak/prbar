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
        }
    }
}
