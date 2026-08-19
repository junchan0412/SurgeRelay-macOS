import AppKit
import SwiftUI

struct ModuleCodeCursorPosition: Equatable {
    let line: Int
    let column: Int
}

final class ModuleLineNumberRulerView: NSRulerView {
    weak var codeTextView: NSTextView?
    private var lineStarts = [0]

    override var requiredThickness: CGFloat {
        let digits = CGFloat(String(max(1, lineStarts.count)).count)
        return max(42, 18 + digits * 8)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let codeTextView,
              let layoutManager = codeTextView.layoutManager,
              let textContainer = codeTextView.textContainer else { return }

        NSColor.controlBackgroundColor.setFill()
        rect.fill()

        let contentBounds = codeTextView.enclosingScrollView?.contentView.bounds ?? .zero
        let glyphRange = layoutManager.glyphRange(
            forBoundingRect: contentBounds,
            in: textContainer
        )
        let textStorage = codeTextView.textStorage
        let textString = textStorage?.string as NSString? ?? ""
        let selectedLine = lineNumber(at: codeTextView.selectedRange().location)

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            _, usedRect, _, lineGlyphRange, _ in
            let characterIndex = layoutManager.characterIndexForGlyph(at: lineGlyphRange.location)
            let lineNumber = self.lineNumber(at: min(characterIndex, textString.length))
            let label = "\(lineNumber)" as NSString
            if lineNumber == selectedLine {
                NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
                NSRect(
                    x: rect.minX,
                    y: usedRect.minY + codeTextView.textContainerInset.height,
                    width: rect.width - 1,
                    height: usedRect.height
                ).fill()
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: 11,
                    weight: lineNumber == selectedLine ? .medium : .regular
                ),
                .foregroundColor: lineNumber == selectedLine
                    ? NSColor.controlAccentColor
                    : NSColor.secondaryLabelColor,
            ]
            let labelSize = label.size(withAttributes: attributes)
            let labelRect = NSRect(
                x: rect.width - labelSize.width - 10,
                y: usedRect.minY + codeTextView.textContainerInset.height,
                width: labelSize.width,
                height: labelSize.height
            )
            label.draw(in: labelRect, withAttributes: attributes)
        }

        NSColor.separatorColor.setFill()
        NSRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
    }

    func refresh() {
        rebuildLineStarts()
        needsDisplay = true
        enclosingScrollView?.tile()
    }

    private func rebuildLineStarts() {
        guard let codeTextView else {
            lineStarts = [0]
            return
        }
        let string = codeTextView.string as NSString
        var starts = [0]
        var searchRange = NSRange(location: 0, length: string.length)
        while searchRange.length > 0 {
            let newlineRange = string.range(of: "\n", options: [], range: searchRange)
            guard newlineRange.location != NSNotFound else { break }
            let nextStart = NSMaxRange(newlineRange)
            starts.append(nextStart)
            searchRange = NSRange(location: nextStart, length: string.length - nextStart)
        }
        lineStarts = starts
    }

    private func lineNumber(at characterIndex: Int) -> Int {
        var lowerBound = 0
        var upperBound = lineStarts.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if lineStarts[middle] <= characterIndex {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return max(1, lowerBound)
    }
}

struct ModuleCodeTextView: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let modules: [RelayModule]
    let selectedModuleID: UUID?
    var onCursorPositionChange: ((ModuleCodeCursorPosition) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCursorPositionChange: onCursorPositionChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.usesFontPanel = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.insertionPointColor = .controlAccentColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 20, height: 16)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = text
        textView.typingAttributes = Coordinator.defaultAttributes
        scrollView.documentView = textView
        let lineNumberRuler = ModuleLineNumberRulerView(
            scrollView: scrollView,
            orientation: .verticalRuler
        )
        lineNumberRuler.codeTextView = textView
        scrollView.verticalRulerView = lineNumberRuler
        scrollView.rulersVisible = true
        lineNumberRuler.refresh()
        context.coordinator.textView = textView
        context.coordinator.lineNumberRuler = lineNumberRuler
        context.coordinator.applyHighlighting(modules: modules, selectedModuleID: selectedModuleID)
        _ = context.coordinator.needsHighlight(text: text, selectedModuleID: selectedModuleID)
        context.coordinator.publishCursorPosition()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.isEditable = isEditable
        if textView.string != text {
            let selectedRange = textView.selectedRange()
            let scrollOrigin = scrollView.contentView.bounds.origin
            context.coordinator.isApplyingUpdate = true
            textView.string = text
            textView.typingAttributes = Coordinator.defaultAttributes
            let validLocation = min(selectedRange.location, (text as NSString).length)
            let validLength = min(selectedRange.length, (text as NSString).length - validLocation)
            textView.setSelectedRange(NSRange(location: validLocation, length: validLength))
            context.coordinator.isApplyingUpdate = false
            scrollView.contentView.setBoundsOrigin(scrollOrigin)
            context.coordinator.lineNumberRuler?.refresh()
        }
        // Re-highlighting runs several regex passes over the whole document; only
        // do it when the text or selection actually changed, so unrelated SwiftUI
        // updates (e.g. switching the detail tab) don't trigger a costly re-scan.
        if context.coordinator.needsHighlight(text: textView.string, selectedModuleID: selectedModuleID) {
            context.coordinator.scheduleHighlighting(modules: modules, selectedModuleID: selectedModuleID)
        }
        context.coordinator.scrollToSelectedModule(selectedModuleID, modules: modules)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        static let defaultFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        static let defaultParagraphStyle: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 2
            style.paragraphSpacing = 0
            style.defaultTabInterval = 28
            return style.copy() as! NSParagraphStyle
        }()
        static let defaultAttributes: [NSAttributedString.Key: Any] = [
            .font: defaultFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: defaultParagraphStyle,
        ]

        // Regex compilation is deterministic, but keep initialization failure local to
        // the highlighting pass so a malformed future pattern cannot crash the editor.
        private static let commentExpression = try? NSRegularExpression(
            pattern: #"^(?:#|//|;).*$"#,
            options: [.anchorsMatchLines]
        )
        private static let subscribedExpression = try? NSRegularExpression(
            pattern: #"^(?:#|//|;)SUBSCRIBED\b.*$"#,
            options: [.anchorsMatchLines]
        )
        private static let sectionExpression = try? NSRegularExpression(
            pattern: #"^\[[^\n]+\]$"#,
            options: [.anchorsMatchLines]
        )
        private static let metadataExpression = try? NSRegularExpression(
            pattern: #"^#![^\n]*"#,
            options: [.anchorsMatchLines]
        )
        private static let urlExpression = try? NSRegularExpression(
            pattern: #"https?://[^\s,\"]+"#
        )

        @Binding private var text: String
        weak var textView: NSTextView?
        weak var lineNumberRuler: ModuleLineNumberRulerView?
        var isApplyingUpdate = false
        private let onCursorPositionChange: ((ModuleCodeCursorPosition) -> Void)?
        private var lastSelectedModuleID: UUID?
        private var lastHighlightedText: String?
        private var lastHighlightedSelection: UUID?
        private var highlightWorkItem: DispatchWorkItem?

        init(
            text: Binding<String>,
            onCursorPositionChange: ((ModuleCodeCursorPosition) -> Void)?
        ) {
            _text = text
            self.onCursorPositionChange = onCursorPositionChange
        }

        /// Returns true (and records the new state) when the text or selection
        /// changed since the last highlight pass; false when nothing changed.
        func needsHighlight(text: String, selectedModuleID: UUID?) -> Bool {
            guard lastHighlightedText != text || lastHighlightedSelection != selectedModuleID else {
                return false
            }
            lastHighlightedText = text
            lastHighlightedSelection = selectedModuleID
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingUpdate, let textView else { return }
            text = textView.string
            publishCursorPosition()
            lineNumberRuler?.refresh()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            publishCursorPosition()
            lineNumberRuler?.needsDisplay = true
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertTab(_:)):
                indentSelection(in: textView)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                unindentSelection(in: textView)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                insertIndentedNewline(in: textView)
                return true
            default:
                return false
            }
        }

        func publishCursorPosition() {
            guard let textView, let onCursorPositionChange else { return }
            let selectedRange = textView.selectedRange()
            let prefix = (textView.string as NSString).substring(
                with: NSRange(location: 0, length: min(selectedRange.location, (textView.string as NSString).length))
            )
            let line = prefix.reduce(into: 1) { result, character in
                if character == "\n" { result += 1 }
            }
            let column = prefix.split(separator: "\n", omittingEmptySubsequences: false).last?.count ?? 0
            onCursorPositionChange(ModuleCodeCursorPosition(line: line, column: column + 1))
        }

        private func indentSelection(in textView: NSTextView) {
            let range = textView.selectedRange()
            guard range.length > 0 else {
                textView.insertText("    ", replacementRange: range)
                return
            }
            let string = textView.string as NSString
            let lineRange = string.lineRange(for: range)
            let selectedLines = string.substring(with: lineRange)
            let replacement = selectedLines
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "    " + String($0) }
                .joined(separator: "\n")
            textView.replaceCharacters(in: lineRange, with: replacement)
            textView.setSelectedRange(NSRange(location: lineRange.location, length: (replacement as NSString).length))
        }

        private func unindentSelection(in textView: NSTextView) {
            let range = textView.selectedRange()
            let string = textView.string as NSString
            let lineRange = string.lineRange(for: range)
            let selectedLines = string.substring(with: lineRange)
            let replacement = selectedLines
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> Substring in
                    if line.hasPrefix("    ") { return line.dropFirst(4) }
                    if line.hasPrefix("\t") { return line.dropFirst() }
                    if line.hasPrefix(" ") { return line.dropFirst() }
                    return line
                }
                .joined(separator: "\n")
            guard replacement != selectedLines else { return }
            textView.replaceCharacters(in: lineRange, with: replacement)
            textView.setSelectedRange(NSRange(location: lineRange.location, length: (replacement as NSString).length))
        }

        private func insertIndentedNewline(in textView: NSTextView) {
            let range = textView.selectedRange()
            let string = textView.string as NSString
            let lineStart = string.lineRange(for: NSRange(location: range.location, length: 0)).location
            let linePrefix = string.substring(with: NSRange(location: lineStart, length: range.location - lineStart))
            let indentation = String(linePrefix.prefix(while: { $0 == " " || $0 == "\t" }))
            textView.insertText("\n\(indentation)", replacementRange: range)
        }

        func scheduleHighlighting(modules: [RelayModule], selectedModuleID: UUID?) {
            highlightWorkItem?.cancel()
            var workItem: DispatchWorkItem!
            workItem = DispatchWorkItem { [weak self] in
                guard let self, self.textView != nil, !workItem.isCancelled else { return }
                self.applyHighlighting(modules: modules, selectedModuleID: selectedModuleID)
            }
            highlightWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(24), execute: workItem)
        }

        func applyHighlighting(modules: [RelayModule], selectedModuleID: UUID?) {
            guard let textStorage = textView?.textStorage else { return }
            let string = textStorage.string
            let fullRange = NSRange(location: 0, length: (string as NSString).length)

            textStorage.beginEditing()
            if fullRange.length > 0 {
                textStorage.setAttributes([
                    .font: Self.defaultFont,
                    .foregroundColor: NSColor.labelColor,
                    .backgroundColor: NSColor.clear,
                    .paragraphStyle: Self.defaultParagraphStyle,
                ], range: fullRange)
            }

            apply(expression: Self.commentExpression, attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
            ], to: textStorage)
            apply(expression: Self.subscribedExpression, attributes: [
                .foregroundColor: NSColor.systemBlue,
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
            ], to: textStorage)
            apply(expression: Self.sectionExpression, attributes: [
                .foregroundColor: NSColor.systemPurple,
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
            ], to: textStorage)
            apply(expression: Self.metadataExpression, attributes: [
                .foregroundColor: NSColor.systemTeal,
            ], to: textStorage)
            apply(expression: Self.urlExpression, attributes: [
                .foregroundColor: NSColor.systemOrange,
            ], to: textStorage)

            applyModuleColors(
                modules: modules,
                selectedModuleID: selectedModuleID,
                textStorage: textStorage
            )
            textStorage.endEditing()
            textView?.typingAttributes = Self.defaultAttributes
            lineNumberRuler?.refresh()
        }

        func scrollToSelectedModule(_ id: UUID?, modules: [RelayModule]) {
            guard let id, id != lastSelectedModuleID, let textView,
                  let module = modules.first(where: { $0.id == id }) else { return }
            lastSelectedModuleID = id
            let key = ModuleMerger.toggleKey(for: module)
            let nsString = textView.string as NSString
            var range = nsString.range(of: "%\(key)%")
            if range.location == NSNotFound { range = nsString.range(of: key) }
            if range.location != NSNotFound {
                textView.scrollRangeToVisible(range)
                textView.setSelectedRange(range)
            }
        }

        private func applyModuleColors(
            modules: [RelayModule],
            selectedModuleID: UUID?,
            textStorage: NSTextStorage
        ) {
            let palette: [NSColor] = [.systemBlue, .systemPurple, .systemOrange, .systemGreen, .systemPink, .systemTeal]
            let colors = Dictionary(uniqueKeysWithValues: modules.enumerated().map {
                (ModuleMerger.toggleKey(for: $0.element), palette[$0.offset % palette.count])
            })
            let selectedKey = selectedModuleID
                .flatMap { id in modules.first(where: { $0.id == id }) }
                .map { ModuleMerger.toggleKey(for: $0) }
            let string = textStorage.string as NSString
            for (key, color) in colors {
                let marker = "%\(key)%"
                var searchRange = NSRange(location: 0, length: string.length)
                while searchRange.length > 0 {
                    let markerRange = string.range(of: marker, options: [], range: searchRange)
                    guard markerRange.location != NSNotFound else { break }
                    let lineRange = string.lineRange(for: markerRange)
                    if markerRange.location == lineRange.location {
                        textStorage.addAttributes([
                            .foregroundColor: color,
                            .backgroundColor: color.withAlphaComponent(key == selectedKey ? 0.16 : 0.06),
                        ], range: lineRange)
                        break
                    }
                    let nextLocation = NSMaxRange(markerRange)
                    searchRange = NSRange(location: nextLocation, length: string.length - nextLocation)
                }
            }
        }

        private func apply(
            expression: NSRegularExpression?,
            attributes: [NSAttributedString.Key: Any],
            to textStorage: NSTextStorage
        ) {
            guard let expression else { return }
            let string = textStorage.string
            let range = NSRange(location: 0, length: (string as NSString).length)
            for match in expression.matches(in: string, range: range) {
                textStorage.addAttributes(attributes, range: match.range)
            }
        }
    }
}
