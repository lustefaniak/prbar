import AppKit
import SwiftUI

/// Reaches the editor's text view from the rest of the Rules tab: the facts
/// panel inserts at the cursor, the trace jumps to a line.
@MainActor
final class RuleEditorController {
    weak var textView: RuleTextView?

    func insert(_ text: String) {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        textView.insertText(text, replacementRange: textView.selectedRange())
    }

    func reveal(line: Int) {
        guard let textView else { return }
        let ns = textView.string as NSString
        var location = 0
        var current = 1
        while current < line, location < ns.length {
            let range = ns.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            current += 1
        }
        let target = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: target.location, length: 0))
        textView.scrollRangeToVisible(target)
        textView.showFindIndicator(for: target)
    }
}

/// A rule file's text: coloured, with line numbers, completion from
/// `RuleCompletion`, and the lines a problem names marked.
struct RuleCodeEditor: NSViewRepresentable {
    let path: String
    let text: String
    let lists: [String]
    /// 1-based lines to mark as wrong.
    let problemLines: Set<Int>
    let controller: RuleEditorController
    let onChange: (String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let textView = RuleTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = RuleTextView.font
        textView.typingAttributes = [.font: RuleTextView.font, .foregroundColor: NSColor.textColor]
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder
        let ruler = LineNumberRuler(textView: textView)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        controller.textView = textView
        context.coordinator.load(textView, path: path, text: text)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? RuleTextView else { return }
        controller.textView = textView
        context.coordinator.parent = self
        textView.stage = RuleCatalog.Stage(path: path)
        textView.lists = lists
        if context.coordinator.path != path || (textView.string != text && !context.coordinator.isEditing) {
            context.coordinator.load(textView, path: path, text: text)
        }
        if textView.problemLines != problemLines {
            textView.problemLines = problemLines
            textView.highlight()
            scroll.verticalRulerView?.needsDisplay = true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RuleCodeEditor
        var path = ""
        var isEditing = false

        init(_ parent: RuleCodeEditor) {
            self.parent = parent
        }

        func load(_ textView: RuleTextView, path: String, text: String) {
            self.path = path
            textView.stage = RuleCatalog.Stage(path: path)
            textView.lists = parent.lists
            textView.problemLines = parent.problemLines
            textView.string = text
            textView.highlight()
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? RuleTextView else { return }
            isEditing = true
            textView.highlight()
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            parent.onChange(textView.string)
            isEditing = false
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? RuleTextView)?.selectionMoved()
        }
    }
}

/// The text view: colours from `RuleHighlighter`, a completion popup from
/// `RuleCompletion`.
final class RuleTextView: NSTextView {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    var stage: RuleCatalog.Stage?
    var lists: [String] = []
    var problemLines: Set<Int> = []

    private let popup = CompletionPopup()
    private var completion: RuleCompletion.Result?
    private var selected = 0

    func highlight() {
        guard let storage = textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: Self.font, .foregroundColor: NSColor.textColor], range: full)
        for span in RuleHighlighter.spans(string) {
            let range = NSRange(location: span.location, length: span.length)
            guard NSMaxRange(range) <= storage.length else { continue }
            storage.addAttribute(.foregroundColor, value: Self.color(span.kind), range: range)
        }
        let ns = string as NSString
        var line = 1
        var location = 0
        while location <= ns.length, !problemLines.isEmpty {
            let range = ns.lineRange(for: NSRange(location: location, length: 0))
            if problemLines.contains(line) {
                storage.addAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.18), range: range)
            }
            if NSMaxRange(range) >= ns.length { break }
            location = NSMaxRange(range)
            line += 1
        }
        storage.endEditing()
    }

    private static func color(_ kind: RuleHighlighter.Kind) -> NSColor {
        switch kind {
        case .comment: return .secondaryLabelColor
        case .key: return .systemPurple
        case .string: return .systemRed
        case .number: return .systemBlue
        case .keyword: return .systemPink
        case .fact: return .systemTeal
        case .function: return .systemOrange
        case .punctuation: return .tertiaryLabelColor
        }
    }

    // MARK: - completion

    override func didChangeText() {
        super.didChangeText()
        guard let event = NSApp.currentEvent, event.type == .keyDown,
              let typed = event.characters, let last = typed.last
        else { closeCompletion(); return }
        if last.isLetter || last.isNumber || last == "." || last == "_" || (last == " " && precededByColon()) {
            showCompletion()
        } else {
            closeCompletion()
        }
    }

    private func precededByColon() -> Bool {
        let cursor = selectedRange().location
        let ns = string as NSString
        return cursor >= 2 && ns.character(at: cursor - 2) == 58
    }

    func selectionMoved() {
        guard popup.isVisible, let completion else { return }
        let cursor = selectedRange().location
        if cursor < completion.tokenStart { closeCompletion() }
    }

    /// Esc opens the list where nothing was typed yet.
    override func complete(_ sender: Any?) {
        showCompletion()
    }

    private func showCompletion() {
        let cursor = selectedRange().location
        let result = RuleCompletion.complete(string, cursor: cursor, stage: stage, lists: lists)
        let typed = (string as NSString).substring(with: NSRange(location: result.tokenStart, length: max(0, cursor - result.tokenStart)))
        // Nothing to add to what's typed: no list.
        let items = result.items.filter { $0.insert != typed }
        guard !items.isEmpty, let window else { closeCompletion(); return }
        completion = RuleCompletion.Result(tokenStart: result.tokenStart, items: items)
        selected = 0
        let rect = firstRect(forCharacterRange: NSRange(location: result.tokenStart, length: 0), actualRange: nil)
        popup.show(items: items, selected: selected, at: NSPoint(x: rect.minX, y: rect.minY), in: window) { [weak self] index in
            self?.accept(index)
        }
    }

    private func closeCompletion() {
        completion = nil
        popup.close()
    }

    private func accept(_ index: Int) {
        guard let completion, completion.items.indices.contains(index) else { return }
        let cursor = selectedRange().location
        let range = NSRange(location: completion.tokenStart, length: max(0, cursor - completion.tokenStart))
        closeCompletion()
        insertText(completion.items[index].insert, replacementRange: range)
    }

    override func keyDown(with event: NSEvent) {
        if popup.isVisible, let completion {
            switch event.keyCode {
            case 125:  // down
                selected = min(selected + 1, completion.items.count - 1)
                popup.select(selected)
                return
            case 126:  // up
                selected = max(selected - 1, 0)
                popup.select(selected)
                return
            case 36, 48, 76:  // return, tab, enter
                accept(selected)
                return
            case 53:  // escape
                closeCompletion()
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        closeCompletion()
        return super.resignFirstResponder()
    }
}

/// The list of completions, in a borderless panel under the caret.
@MainActor
final class CompletionPopup {
    private var panel: NSPanel?
    private let model = Model()

    @MainActor
    @Observable
    final class Model {
        var items: [RuleCompletion.Item] = []
        var selected = 0
        var accept: (Int) -> Void = { _ in }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(items: [RuleCompletion.Item], selected: Int, at point: NSPoint, in window: NSWindow, accept: @escaping (Int) -> Void) {
        model.items = items
        model.selected = selected
        model.accept = accept
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let height = min(CGFloat(items.count), 8) * 34 + 8
        panel.setFrame(NSRect(x: point.x, y: point.y - height - 2, width: 460, height: height), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func select(_ index: Int) {
        model.selected = index
    }

    func close() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.contentView = NSHostingView(rootView: CompletionList(model: model))
        return panel
    }

    private struct CompletionList: View {
        let model: Model

        var body: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.items.enumerated()), id: \.offset) { index, item in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.label).font(.system(size: 12, design: .monospaced))
                                Text(item.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(index == model.selected ? Color.accentColor.opacity(0.25) : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { model.accept(index) }
                            .id(index)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: model.selected) { _, new in proxy.scrollTo(new) }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// Line numbers beside the text, the lines a problem names in red.
final class LineNumberRuler: NSRulerView {
    private weak var textView: RuleTextView?

    init(textView: RuleTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 34
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        let ns = textView.string as NSString
        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var line = 1
        var index = 0
        while index < chars.location {
            index = NSMaxRange(ns.lineRange(for: NSRange(location: index, length: 0)))
            line += 1
        }
        if index > chars.location { line -= 1; index = ns.lineRange(for: NSRange(location: chars.location, length: 0)).location }
        let inset = textView.textContainerInset.height
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        repeat {
            let range = ns.lineRange(for: NSRange(location: min(index, ns.length), length: 0))
            let glyph = layout.glyphIndexForCharacter(at: min(range.location, max(0, ns.length - 1)))
            var lineRect = ns.length == 0 ? .zero : layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            lineRect.origin.y += inset - visible.minY
            let color: NSColor = textView.problemLines.contains(line) ? .systemRed : .tertiaryLabelColor
            let label = "\(line)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: lineRect.minY + (lineRect.height - size.height) / 2), withAttributes: attrs)
            index = NSMaxRange(range)
            line += 1
        } while index < NSMaxRange(chars) && index < ns.length
    }
}
