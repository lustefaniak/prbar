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
    let readiness: ReadinessCoordinator

    // MARK: - Menu-bar state

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var rightClickMenu: NSMenu!

    /// UserDefaults keys mirror @AppStorage in GeneralSettings so the two
    /// stay in sync.
    private static let kBadgeReadyToMerge   = "badgeShowReadyToMerge"
    private static let kBadgeReviewRequested = "badgeShowReviewRequested"
    private static let kBadgeCIFailed       = "badgeShowCIFailed"

    override init() {
        // Single-instance is checked from PRBarApp.init before the App
        // declaration triggers @NSApplicationDelegateAdaptor, so by the
        // time we're here we're already the only PRBar.
        let n = Notifier()
        let p = PRPoller.live()
        let q = ReviewQueueWorker.live()
        let d = DiffStore.sharing(q)
        let rc = RepoConfigStore()
        let coord = ReadinessCoordinator(notifier: n)
        q.configResolver = rc.makeResolver()
        // Resolve the persisted default provider. Stored value can be
        // "auto" (probe-and-pick at launch) or a concrete ProviderID
        // rawValue. Auto tie-breaks to claude per resolveAuto().
        let storedRaw = UserDefaults.standard.string(forKey: "defaultProviderId")
        if storedRaw == ProviderID.autoSentinel || storedRaw == nil {
            q.defaultProviderId = ProviderID.resolveAuto()
        } else if let raw = storedRaw, let id = ProviderID(rawValue: raw) {
            q.defaultProviderId = id
        }
        // Daily cost cap — both presence (toggle) and value persist
        // separately so the cap survives flipping the toggle off/on.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "dailyCostCapEnabled") != nil {
            q.dailyCostCapEnabled = defaults.bool(forKey: "dailyCostCapEnabled")
        }
        let storedCap = defaults.double(forKey: "dailyCostCapUsd")
        if storedCap > 0 {
            q.dailyCostCap = storedCap
        }
        rc.onChange = { [weak q, weak rc] in
            guard let q, let rc else { return }
            q.configResolver = rc.makeResolver()
        }
        // Hand AI-triage settlement to the coordinator so it can flip the
        // per-PR ready bit and (when the queue idles) flush a batched
        // "ready for review" notification.
        q.onReviewSettled = { [weak coord] prNodeId, isWorkerSettled in
            coord?.noteReviewSettled(prNodeId: prNodeId, isWorkerSettled: isWorkerSettled)
        }
        // Feed each successful poll into the coordinator so it can spot
        // newly-arrived review-requested PRs and forget ones that left
        // the inbox.
        p.onPollSuccess = { [weak coord, weak rc, weak q] prs in
            guard let coord, let rc else { return }
            coord.track(prs: prs, configResolver: rc.resolve(owner:repo:))
            // Worker auto-enqueue still happens here so AI triage starts
            // immediately after a poll discovers a new review request.
            q?.enqueueNewReviewRequests(from: prs)
        }
        p.notifier = n
        self.poller = p
        self.notifier = n
        self.queue = q
        self.diffStore = d
        self.repoConfigs = rc
        self.readiness = coord
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
        startBadgeObservation()
        // Settings UI flips UserDefaults; re-render immediately when the
        // user changes a toggle even though `poller.prs` hasn't moved.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshBadge() }
        }
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
        // Image hugs the left, count text reads to its right. AppKit
        // inverts both for the active/highlighted state automatically
        // because the image is template-rendered.
        button.imagePosition = .imageLeft
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = self
        button.action = #selector(statusItemClicked(_:))
    }

    /// Observe `poller.prs` via the Observation framework — every time
    /// the inbox changes, recompute the badge count. Re-arms itself
    /// inside the change handler since `withObservationTracking` only
    /// fires once per registration.
    private func startBadgeObservation() {
        refreshBadge()
        observePollerOnce()
    }

    private func observePollerOnce() {
        withObservationTracking {
            _ = poller.prs
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshBadge()
                self.observePollerOnce()
            }
        }
    }

    @MainActor
    private func refreshBadge() {
        let defaults = UserDefaults.standard
        // Default each toggle to true if the key has never been set so
        // a fresh install lights up the badge instead of staying silent.
        let sources = BadgeCounter.Sources(
            readyToMerge:   defaults.object(forKey: Self.kBadgeReadyToMerge) as? Bool ?? true,
            reviewRequested: defaults.object(forKey: Self.kBadgeReviewRequested) as? Bool ?? true,
            ciFailed:       defaults.object(forKey: Self.kBadgeCIFailed) as? Bool ?? true
        )
        let title = BadgeCounter.title(prs: poller.prs, sources: sources)
        guard let button = statusItem?.button else { return }
        // A leading hair-space (U+200A) keeps the count from kissing the
        // glyph; AppKit doesn't auto-pad image+title status items.
        button.title = title.isEmpty ? "" : "\u{200A}\(title)"
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
            .environment(readiness)
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
