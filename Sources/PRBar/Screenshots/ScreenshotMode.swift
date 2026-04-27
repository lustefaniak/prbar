import Foundation

/// Controls the "marketing screenshot" launch path. When the app is
/// started with `--screenshot-stage <name>` it boots against
/// `ScreenshotFixtures` (no `gh` calls, no UserDefaults writes) and
/// auto-opens exactly the surface the screenshot script wants to
/// capture. One stage per launch keeps the matrix simple and avoids
/// in-app navigation scripting (no Accessibility prompts, no flaky
/// AppleScript).
///
/// All state here is process-global because the alternative — threading
/// a "screenshot stage" parameter through `PRBarApp` → `AppDelegate` →
/// `PopoverView` → child views — adds a permanent test-only API to
/// dozens of constructors. The screenshot path is opt-in via launch
/// argument, so global mutable state is contained.
enum ScreenshotMode {
    enum Stage: String, CaseIterable {
        /// Popover open, segmented control on "My PRs", no row selected.
        /// Captures the top-level glance UI.
        case popoverMyPRs = "popover-my-prs"
        /// Popover open, segmented control on "Inbox" (review-requested
        /// PRs), no row selected.
        case popoverInbox = "popover-inbox"
        /// Popover open with one PR selected → `PRDetailView` visible
        /// inside the 560×640 frame.
        case popoverDetail = "popover-detail"
        /// Standalone full-size detail window opened for one PR. Best
        /// for showing diff annotations + AI verdict at marketing
        /// resolution.
        case windowDetail = "window-detail"
        /// Settings pane open on the General tab.
        case settingsGeneral = "settings-general"
        /// Settings pane open on the Repositories tab.
        case settingsRepositories = "settings-repositories"
        /// Settings pane open on the Diagnostics tab.
        case settingsDiagnostics = "settings-diagnostics"
    }

    /// The stage parsed from `--screenshot-stage <name>`. Nil in normal
    /// runs.
    static let stage: Stage? = parse()

    /// Convenience.
    static var isActive: Bool { stage != nil }

    /// Pre-selected PR for the popover at `popoverDetail`. Set during
    /// AppDelegate boot so `PopoverView.onAppear` can seed its `@State`.
    /// MainActor-isolated because every reader is a SwiftUI view body
    /// or AppKit handler, both of which run on the main actor.
    @MainActor static var initialSelectedPR: InboxPR?

    /// Pre-selected segmented tab for the popover.
    @MainActor static var initialPopoverTab: PopoverTab?

    enum PopoverTab {
        case myPRs, inbox, history
    }

    private static func parse() -> Stage? {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--screenshot-stage"),
              idx + 1 < args.count
        else { return nil }
        let raw = args[idx + 1]
        return Stage(rawValue: raw)
    }
}
