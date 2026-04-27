import AppKit
import SwiftUI
import Sparkle

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
    let failureLogs: FailureLogStore
    let repoConfigs: RepoConfigStore
    let readiness: ReadinessCoordinator
    let actionLog: ActionLogStore

    /// Routes UNUserNotification action-button taps back into services.
    /// Held strongly because UNUserNotificationCenter retains its
    /// delegate weakly.
    private var notificationRouter: NotificationActionRouter!

    // MARK: - Menu-bar state

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var rightClickMenu: NSMenu!

    /// Sparkle updater. `startingUpdater: true` arms the scheduled
    /// background check immediately; `SUEnableAutomaticChecks` /
    /// `SUScheduledCheckInterval` in Info.plist (or Sparkle's defaults)
    /// govern cadence. The standard controller owns its own NSMenuItem
    /// validation, so wiring "Check for Updates…" is just a target +
    /// `checkForUpdates(_:)` action.
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

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
        let p: PRPoller
        let q: ReviewQueueWorker
        if ScreenshotMode.isActive {
            // Screenshot launch path: never poll, never call gh, never
            // touch the network. Build inert services seeded with
            // ScreenshotFixtures so every UI surface has the data it
            // needs to render fully populated.
            p = PRPoller(fetcher: { ScreenshotFixtures.allPRs })
            q = ReviewQueueWorker(diffFetcher: { _, _, _ in "" })
            p._setPRsForScreenshot(ScreenshotFixtures.allPRs)
            q._setReviewsForScreenshot(ScreenshotFixtures.allReviewStates)
        } else {
            p = PRPoller.live()
            q = ReviewQueueWorker.live()
        }
        let d = DiffStore.sharing(q)
        // Reuse the worker's FailureLogStore so the UI's expandable
        // failure-log section reads from the same cache the prompt
        // pipeline already warmed.
        let fls = q.failureLogStore ?? FailureLogStore.live()
        q.failureLogStore = fls
        let rc = RepoConfigStore()
        let coord = ReadinessCoordinator(notifier: n)
        let log = ActionLogStore.live()
        p.actionLog = log
        q.actionLog = log
        // Auto-approve fire posts via gh in the worker; refresh the
        // PR through the poller (with the same race-tolerant double-
        // refresh as user-initiated approve) so the row reflects the
        // new reviewDecision without waiting for the next 60s poll.
        q.onAutoApproved = { [weak p] pr in
            p?.refreshPR(pr)
            Task { @MainActor [weak p] in
                try? await Task.sleep(for: .seconds(1.2))
                p?.refreshPR(pr, force: true)
            }
        }
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
        p.configResolver = rc.makeResolver()
        rc.onChange = { [weak q, weak rc, weak p] in
            guard let q, let rc else { return }
            q.configResolver = rc.makeResolver()
            p?.configResolver = rc.makeResolver()
            // Re-poll so the title-exclude filter applies to anything in
            // the inbox right now, not just future fetches.
            p?.pollNow()
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
        self.failureLogs = fls
        self.repoConfigs = rc
        self.readiness = coord
        self.actionLog = log
        super.init()
        // Install the notification action router *before* requesting
        // authorization so the registered categories are visible the
        // first time macOS shows the auth prompt — otherwise the user
        // may grant permission on a stale category set with no buttons.
        let router = NotificationActionRouter(poller: p)
        router.install()
        self.notificationRouter = router
        // In screenshot mode we deliberately skip the OS auth prompt
        // (would steal focus from the very window we're trying to
        // capture) and the worktree GC pass (no real repos exist).
        if !ScreenshotMode.isActive {
            Task { await n.requestAuthorization() }
            if let mgr = q.checkoutManager {
                Task { await mgr.sweepStaleWorktrees() }
            }
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
        if let stage = ScreenshotMode.stage {
            // Run after the next tick so SwiftUI / AppKit has a chance
            // to install the menu-bar item and finish initial layout
            // before we start opening windows on top of it.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                self.bootstrapScreenshotStage(stage)
                // Give SwiftUI another beat to settle before sampling
                // the window number; popovers in particular don't have
                // their `contentViewController.view.window` populated
                // immediately after `show()`.
                try? await Task.sleep(for: .milliseconds(450))
                self.publishScreenshotWindowID(for: stage)
            }
        }
    }

    /// Marketing-screenshot driver coordination: write the captured
    /// surface's `windowNumber` to a well-known file so the `bin/
    /// screenshots` shell script can pass it to `screencapture -l`
    /// without needing AppleScript / Accessibility permissions.
    /// Polls for up to ~3s because the Settings window in particular
    /// is created asynchronously after `openSettings` returns.
    private func publishScreenshotWindowID(for stage: ScreenshotMode.Stage) {
        Task { @MainActor in
            for _ in 0..<30 {
                let id = self.screenshotWindowNumber(for: stage)
                if id > 0 {
                    let path = URL(fileURLWithPath: "/tmp/prbar-screenshot-window-id.txt")
                    try? "\(id)\n".write(to: path, atomically: true, encoding: .utf8)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func screenshotWindowNumber(for stage: ScreenshotMode.Stage) -> Int {
        switch stage {
        case .popoverMyPRs, .popoverInbox, .popoverDetail:
            return popover.contentViewController?.view.window?.windowNumber ?? 0
        case .windowDetail:
            return screenshotWindow?.windowNumber ?? 0
        case .settingsGeneral, .settingsRepositories, .settingsDiagnostics:
            // SwiftUI's Settings window may not exist immediately after
            // `openSettings(_:)` returns — the selector dispatches
            // asynchronously. Pick the first titled, visible, non-popover
            // window (popover hosts its own NSWindow but it's usually
            // not in `NSApp.windows`; if it is, it has `.borderless`
            // style). Excluding the menu-bar status item (no title).
            return NSApp.windows
                .first(where: { w in
                    w.isVisible
                        && w.styleMask.contains(.titled)
                        && !w.title.isEmpty
                })?
                .windowNumber ?? 0
        }
    }

    /// Bring up the surface that the requested screenshot stage wants
    /// captured, using fixture-seeded services that were installed in
    /// `init` when `ScreenshotMode.isActive`. One stage per launch — the
    /// shell driver loops over stages, killing and relaunching the app
    /// between each, so we never need in-app navigation.
    private func bootstrapScreenshotStage(_ stage: ScreenshotMode.Stage) {
        switch stage {
        case .popoverMyPRs:
            ScreenshotMode.initialPopoverTab = .myPRs
            ScreenshotMode.initialSelectedPR = nil
            togglePopover()
        case .popoverInbox:
            ScreenshotMode.initialPopoverTab = .inbox
            ScreenshotMode.initialSelectedPR = nil
            togglePopover()
        case .popoverDetail:
            ScreenshotMode.initialPopoverTab = .inbox
            ScreenshotMode.initialSelectedPR = ScreenshotFixtures.detailPR(for: stage)
            togglePopover()
        case .windowDetail:
            openScreenshotDetailWindow(ScreenshotFixtures.detailPR(for: stage))
        case .settingsGeneral:
            UserDefaults.standard.set(0, forKey: "com_apple_SwiftUI_Settings_selectedTabIndex")
            openSettings(nil)
        case .settingsRepositories:
            UserDefaults.standard.set(1, forKey: "com_apple_SwiftUI_Settings_selectedTabIndex")
            openSettings(nil)
        case .settingsDiagnostics:
            UserDefaults.standard.set(2, forKey: "com_apple_SwiftUI_Settings_selectedTabIndex")
            openSettings(nil)
        }
    }

    /// Held strongly so the standalone window doesn't dealloc the moment
    /// `bootstrapScreenshotStage` returns. Only used in screenshot mode;
    /// production opens the same view through the SwiftUI `WindowGroup`.
    private var screenshotWindow: NSWindow?

    private func openScreenshotDetailWindow(_ pr: InboxPR) {
        let root = PRDetailWindowView(nodeId: pr.nodeId)
            .environment(poller)
            .environment(notifier)
            .environment(queue)
            .environment(diffStore)
            .environment(failureLogs)
            .environment(repoConfigs)
            .environment(readiness)
            .environment(actionLog)
        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: host)
        window.title = "\(pr.nameWithOwner) #\(pr.numberString) — \(pr.title)"
        window.setContentSize(NSSize(width: 1100, height: 800))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        screenshotWindow = window
    }

    /// Close the popover if it's showing. Used by actions that move the
    /// user out of the popover into a different surface (e.g. opening a
    /// PR in the standalone detail window) so the popover doesn't linger
    /// behind the new window.
    func dismissPopover() {
        guard popover != nil, popover.isShown else { return }
        popover.performClose(nil)
    }

    /// Programmatically open Settings — used by the right-click menu
    /// and any internal caller.
    ///
    /// Two layers:
    ///
    /// 1. If a Settings window already exists in `NSApp.windows`
    ///    (SwiftUI keeps it around after close on modern macOS), just
    ///    bring it back to front. The selector dispatch route below
    ///    is unreliable on the *second* open — SwiftUI's handler
    ///    sometimes no-ops when the window already exists but is
    ///    hidden, so the user clicks "Settings…" and nothing happens.
    /// 2. Otherwise dispatch via `NSApp.sendAction(_:to:nil:)` which
    ///    walks the responder chain and reaches SwiftUI's registered
    ///    `showSettingsWindow:` handler. Falls back to the legacy
    ///    `showPreferencesWindow:` selector on pre-macOS-14.
    ///
    /// Note: `NSApp.perform(...)` looks superficially equivalent but
    /// calls the selector directly on `NSApp` rather than walking the
    /// responder chain — SwiftUI's handler doesn't sit on `NSApp`
    /// itself, so `perform` quietly no-ops. Always use `sendAction`.
    @objc func openSettings(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        if let existing = Self.findExistingSettingsWindow() {
            existing.makeKeyAndOrderFront(sender)
            return
        }
        let modern = Selector(("showSettingsWindow:"))
        if NSApp.sendAction(modern, to: nil, from: sender) { return }
        let legacy = Selector(("showPreferencesWindow:"))
        _ = NSApp.sendAction(legacy, to: nil, from: sender)
    }

    private static func findExistingSettingsWindow() -> NSWindow? {
        NSApp.windows.first { w in
            // SwiftUI's Settings scene window has a stable identifier
            // that contains "Settings". Title is locale-dependent and
            // can be empty while the window is hidden; identifier is
            // stable, so prefer it.
            let id = w.identifier?.rawValue ?? ""
            if id.localizedCaseInsensitiveContains("setting") { return true }
            if id.localizedCaseInsensitiveContains("preference") { return true }
            return false
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
            .environment(failureLogs)
            .environment(repoConfigs)
            .environment(readiness)
            .environment(actionLog)
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
        // Sparkle's SPUStandardUpdaterController validates the menu
        // item itself (greys it out while a check is in-flight), so we
        // just point target+action at the controller and let it do the
        // rest. No keyEquivalent — discoverable through the menu only.
        let checkUpdates = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkUpdates.target = updaterController
        rightClickMenu.addItem(checkUpdates)
        rightClickMenu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit PRBar",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        rightClickMenu.addItem(quit)
    }

    /// Forwarding selector used by AboutView's "Check for Updates…"
    /// button — sent up the responder chain via NSApp.sendAction.
    @objc func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
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
