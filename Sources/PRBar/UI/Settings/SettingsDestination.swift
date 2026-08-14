import AppKit

/// A tab of the Settings window, addressable from code.
///
/// SwiftUI's `Settings` scene selects a tab through the private
/// `com_apple_SwiftUI_Settings_selectedTabIndex` default, which means the
/// index is positional and silently wrong if `SettingsRoot`'s `TabView`
/// order changes. This enum is the single place that mapping lives —
/// screenshot mode and the in-app "take me to the setting that caused
/// this" links both read it, so reordering tabs is one edit rather than a
/// hunt through call sites.
///
/// Keep `tabIndex` in step with `SettingsRoot`.
enum SettingsDestination: String, CaseIterable, Sendable {
    case general
    case reviewDefaults
    case repositories
    case reviewHistory
    case diagnostics

    var tabIndex: Int {
        switch self {
        case .general:        return 0
        case .reviewDefaults: return 1
        case .repositories:   return 2
        case .reviewHistory:  return 3
        case .diagnostics:    return 4
        }
    }

    /// How to refer to this tab in prose, e.g. "Settings → Review defaults".
    var title: String {
        switch self {
        case .general:        return "General"
        case .reviewDefaults: return "Review defaults"
        case .repositories:   return "Repositories"
        case .reviewHistory:  return "Review History"
        case .diagnostics:    return "Diagnostics"
        }
    }

    var settingsPath: String { "Settings → \(title)" }

    /// Pre-select this tab. Separate from opening so `AppDelegate` can
    /// pair it with its own `openSettings` rather than reaching back
    /// through `NSApp.delegate` at launch.
    @MainActor
    func select() {
        UserDefaults.standard.set(
            tabIndex,
            forKey: "com_apple_SwiftUI_Settings_selectedTabIndex"
        )
    }

    /// Select this tab, then open (or raise) the Settings window.
    ///
    /// Dismisses the popover first: `NSPopover.transient` does not close on
    /// its own when another app-internal window becomes key, so it would
    /// otherwise linger behind Settings.
    @MainActor
    static func open(_ destination: SettingsDestination) {
        destination.select()
        let delegate = NSApp.delegate as? AppDelegate
        delegate?.dismissPopover()
        delegate?.openSettings(nil)
    }
}
