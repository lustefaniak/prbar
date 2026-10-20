import AppKit
import SwiftUI
import XCTest
@testable import PRBar

/// Notifications are held back while the popover is open, so the app must
/// learn reliably when it closes. A release build held 680 notifications
/// for a day because the popover's close was never reported.
@MainActor
final class PopoverVisibilityTests: XCTestCase {
    private final class Flags {
        var appeared = 0
        var disappeared = 0
    }

    private struct Probe: View {
        let flags: Flags
        var body: some View {
            Text("probe")
                .frame(width: 100, height: 40)
                .onAppear { flags.appeared += 1 }
                .onDisappear { flags.disappeared += 1 }
        }
    }

    func testClosingThePopoverIsReported() async throws {
        let flags = Flags()
        let popover = NSPopover()
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: Probe(flags: flags))
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 200, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        for _ in 0..<2 {
            popover.show(relativeTo: window.contentView!.bounds, of: window.contentView!, preferredEdge: .minY)
            try await Task.sleep(for: .milliseconds(300))
            popover.performClose(nil)
            try await Task.sleep(for: .milliseconds(300))
        }

        XCTAssertGreaterThanOrEqual(flags.appeared, 1)
        XCTAssertEqual(flags.disappeared, flags.appeared, "every open must be matched by a reported close")
    }
}
