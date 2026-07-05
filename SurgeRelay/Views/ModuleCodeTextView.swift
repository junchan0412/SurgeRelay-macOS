import AppKit
import SwiftUI

struct ModuleCodeTextView: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let modules: [RelayModule]
    let selectedModuleID: UUID?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
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
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 18, height: 16)
        textView.string = text
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.applyHighlighting(modules: modules, selectedModuleID: selectedModuleID)
        _ = context.coordinator.needsHighlight(text: text, selectedModuleID: selectedModuleID)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.isEditable = isEditable
        if textView.string != text {
            context.coordinator.isApplyingUpdate = true
            textView.string = text
            context.coordinator.isApplyingUpdate = false
        }
        // Re-highlighting runs several regex passes over the whole document; only
        // do it when the text or selection actually changed, so unrelated SwiftUI
        // updates (e.g. switching the detail tab) don't trigger a costly re-scan.
        if context.coordinator.needsHighlight(text: textView.string, selectedModuleID: selectedModuleID) {
            context.coordinator.applyHighlighting(modules: modules, selectedModuleID: selectedModuleID)
        }
        context.coordinator.scrollToSelectedModule(selectedModuleID, modules: modules)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        weak var textView: NSTextView?
        var isApplyingUpdate = false
        private var lastSelectedModuleID: UUID?
        private var lastHighlightedText: String?
        private var lastHighlightedSelection: UUID?

        init(text: Binding<String>) {
            _text = text
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
        }

        func applyHighlighting(modules: [RelayModule], selectedModuleID: UUID?) {
            guard let textStorage = textView?.textStorage else { return }
            let string = textStorage.string
            let fullRange = NSRange(location: 0, length: (string as NSString).length)
            guard fullRange.length > 0 else { return }

            textStorage.beginEditing()
            textStorage.setAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.labelColor,
                .backgroundColor: NSColor.clear,
            ], range: fullRange)

            apply(pattern: #"^(?:#|//|;).*$"#, options: [.anchorsMatchLines], attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
            ], to: textStorage)
            apply(pattern: #"^\[[^\n]+\]$"#, options: [.anchorsMatchLines], attributes: [
                .foregroundColor: NSColor.systemPurple,
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
            ], to: textStorage)
            apply(pattern: #"^#![^\n]*"#, options: [.anchorsMatchLines], attributes: [
                .foregroundColor: NSColor.systemTeal,
            ], to: textStorage)
            apply(pattern: #"https?://[^\s,\"]+"#, attributes: [
                .foregroundColor: NSColor.systemOrange,
            ], to: textStorage)

            applyModuleColors(
                modules: modules,
                selectedModuleID: selectedModuleID,
                textStorage: textStorage
            )
            textStorage.endEditing()
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
            for (key, color) in colors {
                apply(
                    pattern: "^%\(NSRegularExpression.escapedPattern(for: key))%.*$",
                    options: [.anchorsMatchLines],
                    attributes: [
                        .foregroundColor: color,
                        .backgroundColor: color.withAlphaComponent(key == selectedKey ? 0.16 : 0.06),
                    ],
                    to: textStorage
                )
            }
        }

        private func apply(
            pattern: String,
            options: NSRegularExpression.Options = [],
            attributes: [NSAttributedString.Key: Any],
            to textStorage: NSTextStorage
        ) {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            let string = textStorage.string
            let range = NSRange(location: 0, length: (string as NSString).length)
            for match in expression.matches(in: string, range: range) {
                textStorage.addAttributes(attributes, range: match.range)
            }
        }
    }
}
