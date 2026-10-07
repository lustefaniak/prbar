import AppKit
import XCTest
@testable import PRBar

@MainActor
final class RuleCodeEditorTests: XCTestCase {
    private func makeEditor() -> (RuleCodeEditor.Coordinator, NSScrollView, RuleTextView, NSWindow) {
        let editor = RuleCodeEditor(
            path: "lists.yaml", text: "", lists: [], problemLines: [],
            controller: RuleEditorController(), onChange: { _ in })
        let coordinator = editor.makeCoordinator()
        let scroll = RuleCodeEditor.makeScrollView(delegate: coordinator)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        scroll.frame = window.contentView!.bounds
        window.contentView!.addSubview(scroll)
        return (coordinator, scroll, scroll.documentView as! RuleTextView, window)
    }

    /// Text layout, and the frame change that follows it, waits for display.
    private func settle(_ window: NSWindow) {
        window.layoutIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func lines(_ n: Int) -> String {
        (1...n).map { "key\($0): value" }.joined(separator: "\n")
    }

    /// A shorter file must still cover the whole clip view, or the strip
    /// below its last line keeps whatever the previous file drew there.
    func testShorterFileStillFillsTheVisibleArea() async {
        let (coordinator, scroll, textView, window) = makeEditor()
        defer { window.close() }
        coordinator.load(textView, path: "decide/10-long.yaml", text: lines(80))
        settle(window)
        coordinator.load(textView, path: "lists.yaml", text: lines(6))
        settle(window)
        XCTAssertGreaterThanOrEqual(textView.frame.height, scroll.contentView.bounds.height)
    }

    func testSwitchingFilesScrollsBackToTheTop() async {
        let (coordinator, scroll, textView, window) = makeEditor()
        defer { window.close() }
        coordinator.load(textView, path: "decide/10-long.yaml", text: lines(200))
        settle(window)
        textView.scroll(NSPoint(x: 0, y: 1500))
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 0)
        coordinator.load(textView, path: "decide/20-other.yaml", text: lines(200))
        settle(window)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0)
    }
}
