import AppKit
import SwiftUI

struct ModuleCodeCursorPosition: Equatable {
    let line: Int
    let column: Int
}

/// Code text view that draws its own left line-number gutter.
///
/// It intentionally does not live inside an `NSScrollView`: on the current macOS
/// SDK a SwiftUI-hosted `NSScrollView` composites its own chrome (scrollers,
/// rulers) but never composites the content inside its `NSClipView`, so the text
/// stayed invisible on screen even though it laid out and drew correctly. Hosting
/// the text view directly (with scrolling provided by a surrounding SwiftUI
/// `ScrollView`) sidesteps that clip-view compositing bug, and moving the line
/// numbers into the text view keeps them aligned and scrolling with the content.
final class CodeTextView: NSTextView {
    static let gutterWidth: CGFloat = 44
    private let gutterView = GutterView()

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        gutterView.textView = self
        gutterView.autoresizingMask = [.height]
        addSubview(gutterView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The gutter is a sibling layer inside the text view; keep it pinned to the
    /// left edge and spanning the full document height so it scrolls with content.
    override func layout() {
        super.layout()
        gutterView.frame = NSRect(x: 0, y: 0, width: Self.gutterWidth, height: bounds.height)
        gutterView.render()
    }

    func refreshGutter() {
        gutterView.frame = NSRect(x: 0, y: 0, width: Self.gutterWidth, height: bounds.height)
        gutterView.render()
    }
}

/// Left line-number gutter. It renders line numbers into its backing layer's
/// contents rather than via `draw(_:)`: on the current macOS SDK an
/// `NSTextView` subclass' `draw(_:)` additions are not composited on screen, but
/// a plain layer-backed sibling view is, so this keeps the numbers visible.
final class GutterView: NSView {
    weak var textView: CodeTextView?
    private var lineStarts = [0]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .topLeft
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    func render() {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              bounds.width > 0, bounds.height > 0 else { return }

        rebuildLineStarts()
        let scale = window?.backingScaleFactor ?? 2
        let size = bounds.size
        let pixelWidth = Int((size.width * scale).rounded())
        let pixelHeight = Int((size.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelWidth,
                pixelsHigh: pixelHeight,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ) else { return }
        rep.size = size

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = context
        // The bitmap context has a bottom-left origin, so convert each item's
        // top-down y (matching the flipped text view) with `size.height - y - h`
        // and draw text upright without flipping the CTM.
        let height = size.height

        NSColor.controlBackgroundColor.setFill()
        NSRect(origin: .zero, size: size).fill()

        let origin = textView.textContainerOrigin
        let nsString = textView.string as NSString
        let selectedLine = lineNumber(at: textView.selectedRange().location)
        let fullGlyphRange = layoutManager.glyphRange(for: textContainer)
        layoutManager.enumerateLineFragments(forGlyphRange: fullGlyphRange) {
            _, usedRect, _, lineGlyphRange, _ in
            let characterIndex = layoutManager.characterIndexForGlyph(at: lineGlyphRange.location)
            let number = self.lineNumber(at: min(characterIndex, nsString.length))
            let topY = usedRect.minY + origin.y
            if number == selectedLine {
                NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
                NSRect(
                    x: 0,
                    y: height - topY - usedRect.height,
                    width: Self.gutterWidth - 1,
                    height: usedRect.height
                ).fill()
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: 11,
                    weight: number == selectedLine ? .medium : .regular
                ),
                .foregroundColor: number == selectedLine
                    ? NSColor.controlAccentColor
                    : NSColor.secondaryLabelColor,
            ]
            let label = "\(number)" as NSString
            let labelSize = label.size(withAttributes: attributes)
            label.draw(
                in: NSRect(
                    x: Self.gutterWidth - labelSize.width - 8,
                    y: height - topY - labelSize.height,
                    width: labelSize.width,
                    height: labelSize.height
                ),
                withAttributes: attributes
            )
        }

        NSColor.separatorColor.setFill()
        NSRect(x: Self.gutterWidth - 1, y: 0, width: 1, height: size.height).fill()

        NSGraphicsContext.current = previous
        layer?.contents = rep.cgImage
    }

    static var gutterWidth: CGFloat { CodeTextView.gutterWidth }

    private func rebuildLineStarts() {
        let string = textView?.string as NSString? ?? ""
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

    func makeNSView(context: Context) -> CodeTextView {
        // Build an explicit TextKit 1 stack. On the current macOS SDK a text view
        // from NSTextView()/scrollableTextView() can be backed by TextKit 2
        // (NSTextLayoutManager), whose rendering does not follow the legacy
        // layoutManager/textStorage APIs this editor relies on for direct syntax
        // highlighting and the line-number gutter — which left the view blank even
        // though its content and layout were present.
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            containerSize: NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)

        let textView = CodeTextView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 400),
            textContainer: textContainer
        )
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
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        // Reserve the gutter on the left; keep normal padding on the right.
        textView.textContainerInset = NSSize(width: CodeTextView.gutterWidth + 8, height: 16)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = text
        textView.typingAttributes = Coordinator.defaultAttributes
        context.coordinator.textView = textView
        context.coordinator.applyHighlighting(modules: modules, selectedModuleID: selectedModuleID)
        _ = context.coordinator.needsHighlight(text: text, selectedModuleID: selectedModuleID)
        textView.refreshGutter()
        context.coordinator.publishCursorPosition()
        return textView
    }

    func updateNSView(_ textView: CodeTextView, context: Context) {
        textView.isEditable = isEditable
        if textView.string != text {
            let selectedRange = textView.selectedRange()
            context.coordinator.isApplyingUpdate = true
            textView.string = text
            textView.typingAttributes = Coordinator.defaultAttributes
            let validLocation = min(selectedRange.location, (text as NSString).length)
            let validLength = min(selectedRange.length, (text as NSString).length - validLocation)
            textView.setSelectedRange(NSRange(location: validLocation, length: validLength))
            context.coordinator.isApplyingUpdate = false
            textView.refreshGutter()
        }
        // Re-highlighting runs several regex passes over the whole document; only
        // do it when the text or selection actually changed, so unrelated SwiftUI
        // updates (e.g. switching the detail tab) don't trigger a costly re-scan.
        if context.coordinator.needsHighlight(text: textView.string, selectedModuleID: selectedModuleID) {
            context.coordinator.scheduleHighlighting(modules: modules, selectedModuleID: selectedModuleID)
        }
        context.coordinator.scrollToSelectedModule(selectedModuleID, modules: modules)
    }

    /// Report the laid-out content height so an enclosing SwiftUI `ScrollView`
    /// can scroll the full document.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CodeTextView, context: Context) -> CGSize? {
        guard let container = nsView.textContainer, let layoutManager = nsView.layoutManager else {
            return nil
        }
        let width = proposal.width ?? nsView.bounds.width
        guard width > 0, width.isFinite else { return nil }
        if abs(nsView.frame.width - width) > 0.5 {
            nsView.setFrameSize(NSSize(width: width, height: nsView.frame.height))
        }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        let height = used.height + nsView.textContainerInset.height * 2
        return CGSize(width: width, height: max(height, 40))
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
        weak var textView: CodeTextView?
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
            textView.refreshGutter()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            publishCursorPosition()
            textView?.needsDisplay = true
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
            guard let textView, let textStorage = textView.textStorage else { return }
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
            textView.typingAttributes = Self.defaultAttributes
            textView.refreshGutter()
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
