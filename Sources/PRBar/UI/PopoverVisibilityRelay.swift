import AppKit

/// Reports when the menu-bar popover opens and closes. The Notifier holds
/// notifications while it's open, so a missed close holds them for as long
/// as the app runs. This can't come from the hosted SwiftUI view: NSPopover
/// only orders its window out on close, so `onDisappear` never fires and
/// `onAppear` fires once.
@MainActor
final class PopoverVisibilityRelay: NSObject, NSPopoverDelegate {
    private let onChange: (Bool) -> Void

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    func popoverDidShow(_ notification: Notification) {
        onChange(true)
    }

    func popoverDidClose(_ notification: Notification) {
        onChange(false)
    }
}
