import AppKit
import SwiftUI

/// Single source of truth for the popover dimensions. Both the
/// NSPopover.contentSize and the inner SwiftUI .frame need to match,
/// otherwise the SwiftUI side collapses to its natural intrinsic size
/// while AppKit allocates the larger frame (or vice versa).
enum PRBarPopoverSize {
    static let width: CGFloat = 560
    static let height: CGFloat = 640
}

/// Owns the menu-bar `NSStatusItem` and the SwiftUI popover. Replaces
/// `MenuBarExtra(.window)` so we can route left-click vs right-click
/// independently — left toggles the popover, right pops a Settings + Quit
/// `NSMenu`. SwiftUI doesn't expose either of those split actions on
/// `MenuBarExtra`, hence the AppDelegate.
///
/// Also owns the live service objects (`PRPoller`, `Notifier`,
/// `ReviewQueueWorker`, `DiffStore`, `RepoConfigStore`) so the popover
/// and Settings scene can both inject them via `.environment(...)`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Services (visible to the SwiftUI side via PRBarApp)

    let poller: PRPoller
    let notifier: Notifier
    let queue: ReviewQueueWorker
    let diffStore: DiffStore
    let repoConfigs: RepoConfigStore

    // MARK: - Menu-bar state

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var rightClickMenu: NSMenu!

    override init() {
        // Single-instance is checked from PRBarApp.init before the App
        // declaration triggers @NSApplicationDelegateAdaptor, so by the
        // time we're here we're already the only PRBar.
        let n = Notifier()
        let p = PRPoller.live()
        let q = ReviewQueueWorker.live()
        let d = DiffStore.sharing(q)
        let rc = RepoConfigStore()
        q.configResolver = rc.makeResolver()
        rc.onChange = { [weak q, weak rc] in
            guard let q, let rc else { return }
            q.configResolver = rc.makeResolver()
        }
        p.notifier = n
        self.poller = p
        self.notifier = n
        self.queue = q
        self.diffStore = d
        self.repoConfigs = rc
        super.init()
        Task { await n.requestAuthorization() }
        if let mgr = q.checkoutManager {
            Task { await mgr.sweepStaleWorktrees() }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        installPopover()
        installRightClickMenu()
    }

    /// Programmatically open Settings — used by the right-click menu.
    /// Settings scene exposes its window through `showSettingsWindow:`
    /// (macOS 14+); fall back to `showPreferencesWindow:` on older.
    @objc func openSettings(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        let modern = Selector(("showSettingsWindow:"))
        if NSApp.responds(to: modern) {
            NSApp.perform(modern, with: nil)
            return
        }
        let legacy = Selector(("showPreferencesWindow:"))
        if NSApp.responds(to: legacy) {
            NSApp.perform(legacy, with: nil)
        }
    }

    // MARK: - private setup

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        let image = NSImage(named: "MenuBarIcon")
        image?.isTemplate = true
        button.image = image
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = self
        button.action = #selector(statusItemClicked(_:))
    }

    private func installPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        // Without an explicit contentSize, NSPopover sizes to whatever
        // SwiftUI reports as the intrinsic content size — which collapses
        // when the inner ScrollView's natural height is small or the
        // detail view's anchor pushes the layout. Pin to a reasonable
        // popover-shape (560 × 640) so the list scrolls inside its frame.
        popover.contentSize = NSSize(width: PRBarPopoverSize.width,
                                     height: PRBarPopoverSize.height)
        let root = PopoverView()
            .frame(width: PRBarPopoverSize.width, height: PRBarPopoverSize.height)
            .environment(poller)
            .environment(notifier)
            .environment(queue)
            .environment(diffStore)
            .environment(repoConfigs)
        popover.contentViewController = NSHostingController(rootView: root)
    }

    private func installRightClickMenu() {
        rightClickMenu = NSMenu()
        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        settings.target = self
        rightClickMenu.addItem(settings)
        rightClickMenu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit PRBar",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        rightClickMenu.addItem(quit)
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return togglePopover() }
        switch event.type {
        case .rightMouseUp:
            showRightClickMenu()
        default:
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Activate so text fields inside the popover (comment editor,
            // settings link, search) can receive keyboard input.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(
                relativeTo: button.bounds,
                of: button,
                preferredEdge: .minY
            )
        }
    }

    private func showRightClickMenu() {
        // Attach the menu to the status item temporarily so AppKit
        // positions it under the icon, then detach so left-clicks still
        // trigger our action selector.
        statusItem.menu = rightClickMenu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
}
