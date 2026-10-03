import AppKit
import SwiftUI

struct ModuleCodeCursorPosition: Equatable {
    let line: Int
    let column: Int
}

struct ModuleCodeLineMetrics {
    var gutterLineStarts = [0]
    var plainLineCount = 1
    var plainLongestLine = 0

    init(text: String) {
        var offset = 0
        var width = 0
        var previousWasCR = false
        for unit in text.utf16 {
            offset += 1
            if unit == 0x0A {
                gutterLineStarts.append(offset)
                if previousWasCR { previousWasCR = false; continue }
            }
            switch unit {
            case 0x0A, 0x0D, 0x85, 0x2028, 0x2029:
                plainLongestLine = max(plainLongestLine, width)
                width = 0
                plainLineCount += 1
                previousWasCR = unit == 0x0D
            default:
                previousWasCR = false
                width += unit == 0x09 ? 4 : 1
            }
        }
        plainLongestLine = max(plainLongestLine, width)
    }
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
    struct MeasurementFullLayoutCounts {
        var requests = 0
        var completions = 0
    }
    private(set) var qaMeasurementFullLayoutCounts: MeasurementFullLayoutCounts? = {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SURGE_RELAY_EDITOR_COMPONENT_MATRIX"] == "1"
            || NativeQAPerformanceRecorder.outputURL(environment: environment) != nil else { return nil }
        return MeasurementFullLayoutCounts()
    }()

    static let plainTextThreshold = 256 * 1024
    static let plainTextLineHeight: CGFloat = 22
    static func usesPlainTextMode(_ text: String) -> Bool {
        (text as NSString).length >= plainTextThreshold
    }
    private(set) var isPlainTextMode = false
    private var plainTextSize: CGSize?
    private var cachedNativeText: String?
    private var cachedLineMetrics: ModuleCodeLineMetrics?
    private static let plainTextAttributes: [NSAttributedString.Key: Any] = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = plainTextLineHeight
        style.maximumLineHeight = plainTextLineHeight
        style.defaultTabInterval = 28
        style.lineBreakMode = .byClipping
        return [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ]
    }()

    static let gutterWidth: CGFloat = 56
    private let gutterView = GutterView()
    /// 查找栏与菜单命令的目标；由 `ModuleCodeEditorController.attach(_:)` 建立。
    weak var editorController: ModuleCodeEditorController?
    private var hasSearchHighlights = false
    private weak var observedClipView: NSClipView?
    private var explicitViewport: NSRect?
    private var isGutterRefreshScheduled = false
    private var measuredContentSizes: [CGFloat: CGSize] = [:]

    override var string: String {
        didSet {
            cachedNativeText = nil
            cachedLineMetrics = nil
            configureDocumentMode(resetAttributes: true)
            gutterView.invalidateLineIndex()
            invalidateContentMeasurement()
        }
    }

    var nativeTextSnapshot: String {
        if let cachedNativeText { return cachedNativeText }
        let result = NativeQAPerformanceRecorder.measure("nativeTextSnapshot.copyUTF8") {
            let source = string as NSString
            if let data = source.data(using: String.Encoding.utf8.rawValue, allowLossyConversion: false) {
                return String(decoding: data, as: UTF8.self)
            }
            var fallback = string
            fallback.makeContiguousUTF8()
            return fallback
        }
        cachedNativeText = result
        return result
    }

    var lineMetrics: ModuleCodeLineMetrics {
        if let cachedLineMetrics { return cachedLineMetrics }
        let metrics = NativeQAPerformanceRecorder.measure("document.scanLines") {
            ModuleCodeLineMetrics(text: nativeTextSnapshot)
        }
        cachedLineMetrics = metrics
        return metrics
    }

    override func keyDown(with event: NSEvent) {
        NativeQAPerformanceRecorder.shared?.keyDown(in: self, eventTimestamp: event.timestamp)
        super.keyDown(with: event)
    }

    override func didChangeText() {
        cachedNativeText = nil
        cachedLineMetrics = nil
        NativeQAPerformanceRecorder.shared?.textChanged(in: self)
        configureDocumentMode(resetAttributes: false)
        gutterView.invalidateLineIndex()
        invalidateContentMeasurement()
        super.didChangeText()
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        gutterView.textView = self
        addSubview(gutterView)
        _ = NativeQAPerformanceRecorder.shared
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Keep the gutter bitmap bounded to the visible document viewport.
    override func layout() {
        super.layout()
        observeScrolling()
        refreshGutter()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeScrolling()
        refreshGutter()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshGutter()
    }

    func updateViewport(_ viewport: NSRect) {
        guard explicitViewport != viewport else { return }
        explicitViewport = viewport
        scheduleGutterRefresh()
    }

    func refreshGutter() {
        guard window != nil else { return }
        let viewport = (explicitViewport
            ?? enclosingScrollView.map { convert($0.contentView.bounds, from: $0.contentView) }
            ?? visibleRect).intersection(bounds)
        guard !viewport.isNull, viewport.height > 0 else { return }
        let frame = NSRect(x: 0, y: viewport.minY, width: Self.gutterWidth, height: viewport.height)
        if gutterView.frame != frame { gutterView.frame = frame }
        gutterView.render()
    }

    func measuredContentSize(forWidth width: CGFloat) -> CGSize? {
        return NativeQAPerformanceRecorder.measure("measuredContentSize") {
            NativeQAPerformanceRecorder.shared?.recordGeometry(width: width, bounds: bounds,
                textStorageLength: textStorage?.length, isPlainTextMode: isPlainTextMode,
                cachedPlainTextSize: plainTextSize, hasTextContainer: textContainer != nil,
                cachedPlainLineCount: cachedLineMetrics?.plainLineCount)
            if isPlainTextMode {
                if plainTextSize == nil { plainTextSize = unwrappedContentSize() }
                guard let size = plainTextSize else { return nil }
                let proposedWidth = width > 0 && width.isFinite ? width : size.width
                return CGSize(width: max(proposedWidth, size.width), height: size.height)
            }
            guard width > 0, width.isFinite, let textStorage, let textContainer else { return nil }
            if let cached = measuredContentSizes[width] { return cached }
            let storage = NSTextStorage(attributedString: textStorage)
            let layout = NSLayoutManager()
            let container = NSTextContainer(containerSize: NSSize(
                width: max(1, width - textContainerInset.width * 2),
                height: .greatestFiniteMagnitude
            ))
            container.lineFragmentPadding = textContainer.lineFragmentPadding
            container.lineBreakMode = textContainer.lineBreakMode
            if let layoutManager {
                layout.usesFontLeading = layoutManager.usesFontLeading
                layout.typesetterBehavior = layoutManager.typesetterBehavior
            }
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            qaMeasurementFullLayoutCounts?.requests += 1
            layout.ensureLayout(for: container)
            if qaMeasurementFullLayoutCounts != nil, layout.firstUnlaidCharacterIndex() >= storage.length {
                qaMeasurementFullLayoutCounts?.completions += 1
            }
            var height = layout.usedRect(for: container).maxY
            if layout.extraLineFragmentTextContainer === container {
                height = max(height, layout.extraLineFragmentRect.maxY)
            }
            let size = CGSize(width: width, height: max(ceil(height + textContainerInset.height * 2), 40))
            if measuredContentSizes.count >= 8 { measuredContentSizes.removeAll(keepingCapacity: true) }
            measuredContentSizes[width] = size
            return size
        }
    }

    func invalidateContentMeasurement() {
        measuredContentSizes.removeAll(keepingCapacity: true)
        plainTextSize = nil
        invalidateIntrinsicContentSize()
    }

    private func configureDocumentMode(resetAttributes: Bool) {
        let nextMode = (textStorage?.length ?? 0) >= Self.plainTextThreshold
        let changed = nextMode != isPlainTextMode
        isPlainTextMode = nextMode
        guard changed || resetAttributes else { return }
        textContainer?.widthTracksTextView = !nextMode
        textContainer?.lineBreakMode = nextMode ? .byClipping : .byWordWrapping
        if nextMode {
            textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            if let textStorage, textStorage.length > 0 {
                textStorage.setAttributes(Self.plainTextAttributes, range: NSRange(location: 0, length: textStorage.length))
            }
            typingAttributes = Self.plainTextAttributes
        } else {
            if let textStorage, textStorage.length > 0 {
                textStorage.setAttributes(ModuleCodeTextView.Coordinator.defaultAttributes, range: NSRange(location: 0, length: textStorage.length))
            }
            typingAttributes = ModuleCodeTextView.Coordinator.defaultAttributes
        }
    }

    private func unwrappedContentSize() -> CGSize {
        return NativeQAPerformanceRecorder.measure("unwrappedContentSize") {
            let metrics = lineMetrics
            return CGSize(
                width: ceil(CGFloat(metrics.plainLongestLine) * 13 + textContainerInset.width * 2 + 16),
                height: max(40, CGFloat(metrics.plainLineCount) * Self.plainTextLineHeight + textContainerInset.height * 2)
            )
        }
    }

    var cursorPosition: ModuleCodeCursorPosition {
        gutterView.cursorPosition(at: selectedRange().location)
    }

    private func observeScrolling() {
        let clipView = enclosingScrollView?.contentView
        guard observedClipView !== clipView else { return }
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedClipView)
        observedClipView = clipView
        guard let clipView else { return }
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollPositionDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }

    @objc private func scrollPositionDidChange(_ notification: Notification) {
        scheduleGutterRefresh()
    }

    private func scheduleGutterRefresh() {
        guard !isGutterRefreshScheduled else { return }
        isGutterRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isGutterRefreshScheduled = false
            self.refreshGutter()
        }
    }

    /// 执行一次可撤销的文本替换。
    ///
    /// 走 `shouldChangeText(in:replacementString:)` / `didChangeText()` 而不是直接
    /// 改 `textStorage`，这样缩进、注释、替换全部会进入 `NSTextView` 的撤销栈，
    /// ⌘Z 才能还原程序化编辑。
    @discardableResult
    func applyEdit(_ edit: CodeEditorEdit) -> Bool {
        guard isEditable,
              NSMaxRange(edit.range) <= (string as NSString).length,
              shouldChangeText(in: edit.range, replacementString: edit.replacement) else {
            return false
        }
        replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        let length = (string as NSString).length
        let location = min(edit.selection.location, length)
        setSelectedRange(NSRange(location: location, length: min(edit.selection.length, length - location)))
        return true
    }

    /// 用 layout manager 的临时属性标记查找结果。
    ///
    /// 临时属性不属于 `textStorage`，因此语法高亮重新设置属性时不会被抹掉，
    /// 也不会污染模块内容本身。
    func applySearchHighlights(_ ranges: [NSRange], current: NSRange?) {
        guard let layoutManager else { return }
        clearSearchHighlights()
        let length = (string as NSString).length
        guard length > 0 else { return }
        for range in ranges where NSMaxRange(range) <= length {
            layoutManager.addTemporaryAttributes(
                [.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.3)],
                forCharacterRange: range
            )
            hasSearchHighlights = true
        }
        if let current, NSMaxRange(current) <= length {
            layoutManager.addTemporaryAttributes(
                [
                    .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.45),
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ],
                forCharacterRange: current
            )
            hasSearchHighlights = true
        }
    }

    func clearSearchHighlights() {
        guard hasSearchHighlights, let layoutManager else { return }
        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: fullRange)
        hasSearchHighlights = false
    }

    /// 编辑器自己处理常用快捷键，这样即使主菜单没有对应项，⌘Z / ⌘F 也可用。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command),
              modifiers.subtracting([.command, .shift, .option]).isEmpty,
              let controller = editorController,
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let hasShift = modifiers.contains(.shift)
        let hasOption = modifiers.contains(.option)
        switch key {
        case "z" where !hasOption:
            if hasShift { controller.redo() } else { controller.undo() }
        case "f" where !hasShift:
            controller.presentFind(showsReplace: hasOption)
        case "g" where !hasOption:
            controller.find(forward: !hasShift)
        case "l" where !hasShift && !hasOption:
            controller.presentGoToLine()
        case "/" where !hasShift && !hasOption:
            controller.toggleComment()
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        guard let controller = editorController, controller.isFindBarPresented else {
            super.cancelOperation(sender)
            return
        }
        controller.dismissFindBar()
    }
}

/// Left line-number gutter. It renders line numbers into its backing layer's
/// contents rather than via `draw(_:)`: on the current macOS SDK an
/// `NSTextView` subclass' `draw(_:)` additions are not composited on screen, but
/// a plain layer-backed sibling view is, so this keeps the numbers visible.
final class GutterView: NSView {
    weak var textView: CodeTextView?
    private var lineStarts = [0]
    private var indexedText: String?

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
        effectiveAppearance.performAsCurrentDrawingAppearance {
            renderBitmap()
        }
    }

    private func renderBitmap() {
        NativeQAPerformanceRecorder.measure("gutter.render") {
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

            NSColor(Design.Palette.canvas).setFill()
            NSRect(origin: .zero, size: size).fill()

            let origin = textView.textContainerOrigin
            let nsString = textView.string as NSString
            let selectedLine = lineNumber(at: textView.selectedRange().location)
            let documentViewport = NSRect(
                x: 0, y: frame.minY - origin.y,
                width: textView.bounds.width, height: bounds.height
            )
            let visibleGlyphRange = layoutManager.glyphRange(forBoundingRectWithoutAdditionalLayout: documentViewport, in: textContainer)
            layoutManager.enumerateLineFragments(forGlyphRange: visibleGlyphRange) {
                _, usedRect, _, lineGlyphRange, _ in
                let characterIndex = layoutManager.characterIndexForGlyph(at: lineGlyphRange.location)
                let number = self.lineNumber(at: min(characterIndex, nsString.length))
                let topY = usedRect.minY + origin.y - self.frame.minY
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

            Design.Palette.nsStroke.setFill()
            NSRect(x: Self.gutterWidth - 1, y: 0, width: 1, height: size.height).fill()

            NSGraphicsContext.current = previous
            layer?.contentsScale = scale
            layer?.contents = rep.cgImage
        }
    }

    static var gutterWidth: CGFloat { CodeTextView.gutterWidth }

    func invalidateLineIndex() {
        indexedText = nil
    }

    func cursorPosition(at location: Int) -> ModuleCodeCursorPosition {
        rebuildLineStarts()
        let string = indexedText as NSString? ?? ""
        let offset = min(max(0, location), string.length)
        let line = lineNumber(at: offset)
        let start = lineStarts[line - 1]
        let column = string.substring(with: NSRange(location: start, length: offset - start)).count + 1
        return ModuleCodeCursorPosition(line: line, column: column)
    }

    private func rebuildLineStarts() {
        guard indexedText == nil else { return }
        NativeQAPerformanceRecorder.measure("gutter.rebuildLineStarts") {
            guard let textView else { return }
            indexedText = textView.nativeTextSnapshot
            lineStarts = textView.lineMetrics.gutterLineStarts
        }
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

enum ModuleCodeSyntaxRanges {
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

    static func compute(in text: String) -> [[NSRange]] {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return [commentExpression, subscribedExpression, sectionExpression, metadataExpression, urlExpression].map { expression in
            guard !Task.isCancelled, let expression else { return [] }
            var matches: [NSRange] = []
            expression.enumerateMatches(in: text, options: [.reportProgress], range: range) { match, _, stop in
                if Task.isCancelled { stop.pointee = true }
                else if let match { matches.append(match.range) }
            }
            return matches
        }
    }
}

struct ModuleCodeTextView: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let modules: [RelayModule]
    let selectedModuleID: UUID?
    var controller: ModuleCodeEditorController? = nil
    var onCursorPositionChange: ((ModuleCodeCursorPosition) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            controller: controller,
            onCursorPositionChange: onCursorPositionChange
        )
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
        textView.backgroundColor = NSColor(Design.Palette.canvas)
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        // 系统 find bar 需要依附 NSScrollView，这里的编辑器有意不放进
        // NSScrollView，改由 ModuleCodeSearchBar 提供查找与替换。
        textView.usesFindPanel = false
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
        textView.isVerticallyResizable = false
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
        if !textView.isPlainTextMode { textView.typingAttributes = Coordinator.defaultAttributes }
        context.coordinator.textView = textView
        controller?.attach(textView)
        controller?.setEditable(isEditable)
        context.coordinator.applyHighlighting(modules: modules, selectedModuleID: selectedModuleID)
        _ = context.coordinator.needsHighlight(text: text, selectedModuleID: selectedModuleID)
        textView.refreshGutter()
        context.coordinator.publishCursorPosition()
        return textView
    }

    func updateNSView(_ textView: CodeTextView, context: Context) {
        textView.isEditable = isEditable
        controller?.setEditable(isEditable)
        var currentText = textView.nativeTextSnapshot
        if currentText != text {
            let selectedRange = textView.selectedRange()
            context.coordinator.isApplyingUpdate = true
            textView.string = text
            if !textView.isPlainTextMode { textView.typingAttributes = Coordinator.defaultAttributes }
            let validLocation = min(selectedRange.location, (text as NSString).length)
            let validLength = min(selectedRange.length, (text as NSString).length - validLocation)
            textView.setSelectedRange(NSRange(location: validLocation, length: validLength))
            context.coordinator.isApplyingUpdate = false
            textView.refreshGutter()
            // 外部重新载入的内容与旧撤销栈不再对应，清空后重新计算查找结果。
            controller?.resetForReloadedContent()
            currentText = textView.nativeTextSnapshot
        }
        // Re-highlighting runs several regex passes over the whole document; only
        // do it when the text or selection actually changed, so unrelated SwiftUI
        // updates (e.g. switching the detail tab) don't trigger a costly re-scan.
        if context.coordinator.needsHighlight(text: currentText, selectedModuleID: selectedModuleID) {
            context.coordinator.scheduleHighlighting(modules: modules, selectedModuleID: selectedModuleID)
        }
        context.coordinator.scrollToSelectedModule(selectedModuleID, modules: modules)
    }

    /// Report the laid-out content height so an enclosing SwiftUI `ScrollView`
    /// can scroll the full document.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CodeTextView, context: Context) -> CGSize? {
        nsView.measuredContentSize(forWidth: proposal.width ?? nsView.bounds.width)
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

        @Binding private var text: String
        weak var textView: CodeTextView?
        var isApplyingUpdate = false
        /// 编辑器自带的撤销栈。
        ///
        /// 不依赖窗口的 `UndoManager`：SwiftUI 承载的窗口不保证把它接进
        /// Edit 菜单，而每个编辑器拥有独立撤销栈也避免了预览和文本编辑器互相干扰。
        private let editorUndoManager = UndoManager()
        private let controller: ModuleCodeEditorController?
        private let onCursorPositionChange: ((ModuleCodeCursorPosition) -> Void)?
        private var lastSelectedModuleID: UUID?
        private var lastHighlightedText: String?
        private var lastHighlightedSelection: UUID?
        private var highlightTask: Task<Void, Never>?
        private var highlightGeneration = 0

        deinit { highlightTask?.cancel() }

        init(
            text: Binding<String>,
            controller: ModuleCodeEditorController?,
            onCursorPositionChange: ((ModuleCodeCursorPosition) -> Void)?
        ) {
            _text = text
            self.controller = controller
            self.onCursorPositionChange = onCursorPositionChange
            editorUndoManager.levelsOfUndo = 200
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            editorUndoManager
        }

        /// Returns true (and records the new state) when the text or selection
        /// changed since the last highlight pass; false when nothing changed.
        func needsHighlight(text: String, selectedModuleID: UUID?) -> Bool {
            return NativeQAPerformanceRecorder.measure("needsHighlight") {
                guard lastHighlightedText?.utf8.count != text.utf8.count
                    || lastHighlightedText?.utf16.elementsEqual(text.utf16) != true
                    || lastHighlightedSelection != selectedModuleID else {
                    return false
                }
                lastHighlightedText = text
                lastHighlightedSelection = selectedModuleID
                return true
            }
        }

        func textDidChange(_ notification: Notification) {
            NativeQAPerformanceRecorder.measure("binding.textDidChange") {
                guard !isApplyingUpdate, let textView else { return }
                let changedText = NativeQAPerformanceRecorder.measure("binding.readString") { textView.nativeTextSnapshot }
                NativeQAPerformanceRecorder.measure("binding.assignString") { text = changedText }
                publishCursorPosition()
                textView.refreshGutter()
                controller?.textDidChange()
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            publishCursorPosition()
            controller?.selectionDidChange()
            textView?.refreshGutter()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let codeTextView = textView as? CodeTextView else { return false }
            switch commandSelector {
            case #selector(NSResponder.insertTab(_:)):
                codeTextView.applyEdit(CodeEditorTextTransform.indent(
                    in: textView.string,
                    selection: textView.selectedRange()
                ))
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                guard let edit = CodeEditorTextTransform.unindent(
                    in: textView.string,
                    selection: textView.selectedRange()
                ) else { return true }
                codeTextView.applyEdit(edit)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                codeTextView.applyEdit(CodeEditorTextTransform.newlineKeepingIndentation(
                    in: textView.string,
                    selection: textView.selectedRange()
                ))
                return true
            default:
                return false
            }
        }

        func publishCursorPosition() {
            guard let textView, let onCursorPositionChange else { return }
            onCursorPositionChange(textView.cursorPosition)
        }

        func scheduleHighlighting(modules: [RelayModule], selectedModuleID: UUID?) {
            applyHighlighting(modules: modules, selectedModuleID: selectedModuleID)
        }

        func applyHighlighting(modules: [RelayModule], selectedModuleID: UUID?) {
            highlightTask?.cancel()
            highlightGeneration += 1
            guard let textView, !textView.isPlainTextMode, let textStorage = textView.textStorage else { return }
            let source = textStorage.string
            let generation = highlightGeneration
            highlightTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(24)) } catch { return }
                let worker = Task.detached(priority: .userInitiated) {
                    ModuleCodeSyntaxRanges.compute(in: source)
                }
                let ranges = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: { worker.cancel() }
                guard !Task.isCancelled, let self, self.highlightGeneration == generation,
                      let textView = self.textView, !textView.isPlainTextMode,
                      textView.string.utf16.elementsEqual(source.utf16), let storage = textView.textStorage else { return }
                let attributes: [[NSAttributedString.Key: Any]] = [
                    [.foregroundColor: NSColor.secondaryLabelColor],
                    [.foregroundColor: Design.Palette.nsAccent, .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)],
                    [.foregroundColor: Design.Palette.nsAccent, .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)],
                    [.foregroundColor: Design.Palette.nsAccent],
                    [.foregroundColor: NSColor.secondaryLabelColor],
                ]
                NativeQAPerformanceRecorder.measure("highlight.attributes") {
                    storage.beginEditing()
                    storage.setAttributes(Self.defaultAttributes, range: NSRange(location: 0, length: storage.length))
                    for (index, group) in ranges.enumerated() {
                        for range in group { storage.addAttributes(attributes[index], range: range) }
                    }
                    self.applyModuleColors(modules: modules, selectedModuleID: selectedModuleID, textStorage: storage)
                    storage.endEditing()
                    textView.typingAttributes = Self.defaultAttributes
                }
                textView.refreshGutter()
                self.highlightTask = nil
            }
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
            let palette: [NSColor] = [.controlAccentColor]
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

    }
}
