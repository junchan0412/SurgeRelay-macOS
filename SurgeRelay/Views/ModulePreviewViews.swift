import AppKit
import SwiftUI

/// Inline, editable preview of a single module's converted result. Replaces the
/// old preview window; lives in the detail pane's “预览” tab.
struct ModulePreviewPane: View {
    @Environment(AppModel.self) private var model
    let module: RelayModule
    @State private var text = ""
    @State private var savedText = ""
    @State private var isLoading = true
    @State private var isWriting = false
    @State private var errorMessage: String?
    @State private var showsComparison = false

    private var currentModule: RelayModule {
        model.modules.first(where: { $0.id == module.id }) ?? module
    }

    var body: some View {
        VStack(spacing: 0) {
            if currentModule.hasOverrideConflict {
                HStack(spacing: 10) {
                    Label("上游内容已变化，请确认本地编辑", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("比较…") { showsComparison = true }
                    Button("保留本地编辑") {
                        Task { await model.acceptOverrideConflict(moduleID: module.id) }
                    }
                }
                .padding(10)
                .background(.orange.opacity(0.08))
                Divider()
            }
            ModuleCodeTextView(
                text: $text,
                isEditable: !isLoading,
                modules: [module],
                selectedModuleID: module.id
            )
            .ignoresSafeArea(.container, edges: .top)

            Divider()
            HStack(spacing: 12) {
                Button("恢复") { restore() }
                    .disabled(isWriting || isLoading)
                if !isLoading, text != savedText {
                    Text("有尚未写入的修改")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("保存") { write() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(isWriting || isLoading || text == savedText)
            }
            .padding(12)
        }
        .task(id: module.id) { await load() }
        .alert("无法完成操作", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $showsComparison) {
            OverrideComparisonView(module: currentModule)
                .environment(model)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let content = try await model.previewContent(for: module)
            text = content
            savedText = content
        } catch {
            errorMessage = "无法预览转换结果：\(error.localizedDescription)"
        }
    }

    private func write() {
        isWriting = true
        Task {
            defer { isWriting = false }
            do {
                try await model.savePreviewContent(text, for: module)
                savedText = text
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func restore() {
        isWriting = true
        Task {
            defer { isWriting = false }
            do {
                let restored = try await model.restorePreviewContent(for: module)
                text = restored
                savedText = restored
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct OverrideComparisonView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let module: RelayModule
    @State private var upstream = ""
    @State private var local = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("上游与本地编辑").font(.headline)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            HSplitView {
                comparisonColumn("最新上游", text: upstream)
                comparisonColumn("当前本地编辑", text: local)
            }
        }
        .frame(minWidth: 920, minHeight: 560)
        .task {
            do {
                async let upstreamValue = model.convertedPreviewContent(for: module)
                async let localValue = model.previewContent(for: module)
                (upstream, local) = try await (upstreamValue, localValue)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .alert("无法载入比较", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) { Button("好", role: .cancel) {} } message: { Text(errorMessage ?? "") }
    }

    private func comparisonColumn(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption.weight(.semibold)).padding(10)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
        }
    }
}

/// Inline, read-only preview of the merged final module.
struct CombinedPreviewPane: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var enabledModules: [RelayModule] {
        ModuleRefreshPlanner.combinedContributorModules(
            in: model.modules,
            combinedModuleEnabled: model.settings.combinedModuleEnabled
        )
    }

    private var reloadToken: String {
        "\(model.settings.combinedModuleEnabled)-" + enabledModules.map { "\($0.id.uuidString)-\($0.contentHash ?? "")" }.joined()
    }

    var body: some View {
        ModuleCodeTextView(
            text: .constant(text),
            isEditable: false,
            modules: enabledModules,
            selectedModuleID: nil
        )
        .ignoresSafeArea(.container, edges: .top)
        .overlay {
            if !isLoading, text.isEmpty {
                ContentUnavailableView("没有可预览的内容", systemImage: "doc.text.magnifyingglass")
            }
        }
        .task(id: reloadToken) { await load() }
        .alert("无法完成操作", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            text = try await model.combinedPreviewContent()
        } catch {
            errorMessage = "无法预览最终模块：\(error.localizedDescription)"
        }
    }
}

private struct ModuleCodeTextView: NSViewRepresentable {
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
