import AppKit
import SwiftUI

struct NativeTextEditor: NSViewRepresentable {
    @Bindable var document: EditorDocument
    let fontSize: Double
    let highlighter: SyntaxHighlighter
    var targetLine: Int?

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document, highlighter: highlighter)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CodeTextView(usingTextLayoutManager: true)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.string = document.text
        textView.isEditable = document.isEditable
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.verticalRulerView = LineNumberRulerView(textView: textView)

        context.coordinator.textView = textView
        context.coordinator.installSelectionObserver()
        context.coordinator.scheduleHighlight(for: document.text, fileURL: document.url)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CodeTextView else { return }
        context.coordinator.document = document
        textView.isEditable = document.isEditable
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)

        if textView.string != document.text, !context.coordinator.isApplyingDocumentUpdate {
            context.coordinator.isApplyingDocumentUpdate = true
            let selectedRange = textView.selectedRange()
            textView.string = document.text
            textView.setSelectedRange(NSIntersectionRange(selectedRange, NSRange(location: 0, length: (document.text as NSString).length)))
            context.coordinator.isApplyingDocumentUpdate = false
            context.coordinator.scheduleHighlight(for: document.text, fileURL: document.url)
        }

        if let targetLine, context.coordinator.lastTargetLine != targetLine {
            context.coordinator.lastTargetLine = targetLine
            textView.scrollTo(line: targetLine)
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.cancel()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var document: EditorDocument
        let highlighter: SyntaxHighlighter
        fileprivate weak var textView: CodeTextView?
        var highlightTask: Task<Void, Never>?
        var selectionObserver: NSObjectProtocol?
        var isApplyingDocumentUpdate = false
        var lastTargetLine: Int?

        init(document: EditorDocument, highlighter: SyntaxHighlighter) {
            self.document = document
            self.highlighter = highlighter
        }

        func installSelectionObserver() {
            guard let textView else { return }
            selectionObserver = NotificationCenter.default.addObserver(
                forName: NSTextView.didChangeSelectionNotification,
                object: textView,
                queue: .main
            ) { [weak textView] _ in
                Task { @MainActor in textView?.needsDisplay = true }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingDocumentUpdate, let textView else { return }
            document.replaceText(textView.string)
            scheduleHighlight(for: textView.string, fileURL: document.url)
            (textView.enclosingScrollView?.verticalRulerView as? LineNumberRulerView)?.needsDisplay = true
        }

        func scheduleHighlight(for text: String, fileURL: URL) {
            highlightTask?.cancel()
            guard document.highlightingEnabled else {
                textView?.textStorage?.setAttributes(baseAttributes, range: NSRange(location: 0, length: (text as NSString).length))
                return
            }

            let generation = document.highlightGeneration
            highlightTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(45))
                guard !Task.isCancelled, let self else { return }
                do {
                    guard let update = try await highlighter.highlight(text: text, url: fileURL) else { return }
                    guard !Task.isCancelled,
                          generation == document.highlightGeneration,
                          textView?.string == text else { return }
                    apply(update)
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
            }
        }

        private var baseAttributes: [NSAttributedString.Key: Any] {
            [
                .font: NSFont.monospacedSystemFont(ofSize: textView?.font?.pointSize ?? 13, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ]
        }

        private func apply(_ update: SyntaxUpdate) {
            guard let storage = textView?.textStorage else { return }
            let validRange = NSIntersectionRange(update.affectedRange, NSRange(location: 0, length: storage.length))
            storage.beginEditing()
            storage.setAttributes(baseAttributes, range: validRange)
            for span in update.spans {
                let range = NSIntersectionRange(span.range, NSRange(location: 0, length: storage.length))
                guard range.length > 0 else { continue }
                storage.addAttribute(.foregroundColor, value: color(for: span.name), range: range)
            }
            storage.endEditing()
        }

        private func color(for capture: String) -> NSColor {
            if capture.contains("comment") { return .secondaryLabelColor }
            if capture.contains("string") { return NSColor.systemRed }
            if capture.contains("number") || capture.contains("constant") { return NSColor.systemOrange }
            if capture.contains("keyword") || capture.contains("operator") { return NSColor.systemPink }
            if capture.contains("type") || capture.contains("class") { return NSColor.systemTeal }
            if capture.contains("function") || capture.contains("method") { return NSColor.systemPurple }
            if capture.contains("property") || capture.contains("field") { return NSColor.systemBlue }
            if capture.contains("tag") || capture.contains("attribute") { return NSColor.systemIndigo }
            return .labelColor
        }

        func cancel() {
            highlightTask?.cancel()
            if let selectionObserver {
                NotificationCenter.default.removeObserver(selectionObserver)
            }
        }

    }
}

@MainActor
fileprivate final class CodeTextView: NSTextView {
    private static let bracketPairs: [String: String] = [
        "(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'"
    ]

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard isEditable,
              let value = insertString as? String,
              value.count == 1,
              let closing = Self.bracketPairs[value],
              selectedRange().length == 0 else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        super.insertText(value + closing, replacementRange: replacementRange)
        moveBackward(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawCurrentLineHighlight()
        super.draw(dirtyRect)
    }

    private func drawCurrentLineHighlight() {
        guard window?.firstResponder === self else { return }
        let source = string as NSString
        let lineRange = source.lineRange(for: NSRange(location: min(selectedRange().location, source.length), length: 0))
        let prefix = source.substring(to: lineRange.location)
        let lineIndex = prefix.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        }
        let lineHeight = max(font?.defaultLineHeight ?? 17, 17)
        let y = textContainerInset.height + CGFloat(lineIndex) * lineHeight
        NSColor.controlAccentColor.withAlphaComponent(0.07).setFill()
        NSRect(x: 0, y: y, width: bounds.width, height: lineHeight).fill()
    }

    func scrollTo(line: Int) {
        guard line > 0 else { return }
        let source = string as NSString
        var location = 0
        var current = 1
        while current < line, location < source.length {
            let range = source.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            current += 1
        }
        let target = NSRange(location: min(location, source.length), length: 0)
        setSelectedRange(target)
        scrollRangeToVisible(target)
        window?.makeFirstResponder(self)
    }
}

private final class LineNumberRulerView: NSRulerView {
    weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 48
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let scrollView = textView.enclosingScrollView else { return }
        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        let lineHeight = max(textView.font?.defaultLineHeight ?? 17, 17)
        let visible = scrollView.contentView.bounds
        let inset = textView.textContainerInset.height
        let firstLine = max(0, Int(floor((visible.minY - inset) / lineHeight)))
        let lastLine = max(firstLine, Int(ceil((visible.maxY - inset) / lineHeight)))
        let totalLines = textView.string.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]

        for index in firstLine...min(lastLine, totalLines - 1) {
            let label = "\(index + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            let y = inset + CGFloat(index) * lineHeight + (lineHeight - size.height) / 2 - visible.minY
            label.draw(at: NSPoint(x: ruleThickness - size.width - 9, y: y), withAttributes: attributes)
        }
    }
}

private extension NSFont {
    var defaultLineHeight: CGFloat {
        ascender - descender + leading
    }
}
