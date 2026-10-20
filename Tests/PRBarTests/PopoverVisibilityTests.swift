import AppKit
import SwiftUI
import XCTest
@testable import PRBar

/// Notifications are held back while the popover is open, so the app must
/// learn reliably when it closes. A release build held 680 notifications
/// for a day because the popover's close was never reported.
@MainActor
final class PopoverVisibilityTests: XCTestCase {
    func testEveryOpenAndCloseIsReported() async throws {
        var reported: [Bool] = []
        let relay = PopoverVisibilityRelay { reported.append($0) }
        let popover = NSPopover()
        popover.animates = false
        popover.delegate = relay
        popover.contentViewController = NSHostingController(rootView: Text("probe").frame(width: 100, height: 40))
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

        XCTAssertEqual(reported, [true, false, true, false])
    }
}
