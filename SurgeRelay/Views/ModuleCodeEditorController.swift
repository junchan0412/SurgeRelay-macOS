import AppKit
import Observation
import SwiftUI

/// 查找栏中需要获得键盘焦点的输入框。
enum ModuleCodeEditorFocusTarget: Equatable {
    case find
    case replace
    case line
}

/// 模块文本编辑器的查找 / 替换 / 跳转状态与命令入口。
///
/// SwiftUI 的查找栏只读写这里的状态，AppKit 的 `CodeTextView` 只负责执行选区、
/// 高亮和可撤销的文本替换，两侧共享同一份匹配结果。
@MainActor
@Observable
final class ModuleCodeEditorController {
    var isFindBarPresented = false
    var showsReplaceRow = false
    var showsGoToLineRow = false
    var findText = ""
    var replacementText = ""
    var isCaseSensitive = false
    var usesRegularExpression = false
    var lineInput = ""
    var focusTarget: ModuleCodeEditorFocusTarget?
    private(set) var matchCount = 0
    private(set) var currentMatchNumber: Int?
    private(set) var isEditable = false
    private(set) var canUndo = false
    private(set) var canRedo = false
    private(set) var replaceAllSummary: String?
    private(set) var isSearching = false
    private(set) var isReplacingAll = false

    @ObservationIgnored private(set) weak var textView: CodeTextView?
    @ObservationIgnored private var visibleViewport: CGRect?
    @ObservationIgnored private var matches: [NSRange] = []
    @ObservationIgnored private var currentMatchIndex: Int?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration: UInt64 = 0
    @ObservationIgnored private var textRevision: UInt64 = 0
    @ObservationIgnored private var matchedRevision: UInt64?
    @ObservationIgnored private var matchedQuery: CodeSearchQuery?
    @ObservationIgnored private var pendingRevision: UInt64?
    @ObservationIgnored private var pendingQuery: CodeSearchQuery?
    @ObservationIgnored private var pendingSearchAction: (@MainActor () -> Void)?
    @ObservationIgnored private var replacementTask: Task<Void, Never>?
    @ObservationIgnored private var replacementGeneration: UInt64 = 0

    deinit {
        searchTask?.cancel()
        replacementTask?.cancel()
    }

    var query: CodeSearchQuery {
        CodeSearchQuery(
            text: findText,
            isCaseSensitive: isCaseSensitive,
            usesRegularExpression: usesRegularExpression
        )
    }

    var matchSummary: String {
        if let error = CodeSearchEngine.regularExpressionErrorMessage(for: query) { return error }
        if query.isEmpty { return "" }
        if isSearching { return "正在查找…" }
        if matchCount >= CodeSearchEngine.maximumMatchCount {
            return currentMatchNumber.map { "第 \($0) / 前 \(matchCount) 个" } ?? "前 \(matchCount) 个结果"
        }
        return CodeSearchEngine.matchSummary(matchCount: matchCount, currentNumber: currentMatchNumber)
    }

    var hasInvalidRegularExpression: Bool {
        CodeSearchEngine.regularExpressionErrorMessage(for: query) != nil
    }

    var lineCount: Int {
        textView.map { CodeEditorTextTransform.lineCount(in: $0.string) } ?? 1
    }

    // MARK: - Text view binding

    func attach(_ textView: CodeTextView) {
        cancelReplacement()
        self.textView?.editorController = nil
        self.textView = textView
        textRevision &+= 1
        textView.editorController = self
        if let visibleViewport { textView.updateViewport(visibleViewport) }
        refreshEditingState()
        refreshMatches()
    }

    func updateViewport(_ viewport: CGRect) {
        visibleViewport = viewport
        textView?.updateViewport(viewport)
    }

    func setEditable(_ isEditable: Bool) {
        guard self.isEditable != isEditable else { return }
        self.isEditable = isEditable
        if !isEditable {
            showsReplaceRow = false
            cancelReplacement()
        }
    }

    /// 文本或选区变化后同步匹配结果和撤销状态。
    func textDidChange() {
        cancelReplacement()
        textRevision &+= 1
        replaceAllSummary = nil
        refreshMatches()
        refreshEditingState()
    }

    func selectionDidChange() {
        guard isFindBarPresented, !isSearching, !matches.isEmpty, let textView else { return }
        if let index = CodeSearchEngine.matchIndex(in: matches, equalTo: textView.selectedRange()) {
            currentMatchIndex = index
            currentMatchNumber = index + 1
            textView.applySearchHighlights(matches, current: matches[index])
        } else if currentMatchIndex != nil {
            currentMatchIndex = nil
            currentMatchNumber = nil
            textView.applySearchHighlights(matches, current: nil)
        }
    }

    func refreshEditingState() {
        let undoManager = textView?.undoManager
        canUndo = undoManager?.canUndo ?? false
        canRedo = undoManager?.canRedo ?? false
    }

    /// 载入新内容后重置查找结果与撤销历史。
    func resetForReloadedContent() {
        cancelReplacement()
        textRevision &+= 1
        textView?.undoManager?.removeAllActions()
        replaceAllSummary = nil
        currentMatchIndex = nil
        currentMatchNumber = nil
        refreshMatches()
        refreshEditingState()
    }

    // MARK: - Find bar

    func presentFind(showsReplace: Bool = false) {
        if let textView, textView.selectedRange().length > 0 {
            let selected = (textView.string as NSString).substring(with: textView.selectedRange())
            if !selected.contains("\n") { findText = selected }
        }
        isFindBarPresented = true
        showsGoToLineRow = false
        if showsReplace, isEditable { showsReplaceRow = true }
        focusTarget = showsReplace && isEditable ? .replace : .find
        refreshMatches()
    }

    func presentGoToLine() {
        isFindBarPresented = true
        showsGoToLineRow = true
        focusTarget = .line
    }

    func dismissFindBar() {
        cancelReplacement()
        isFindBarPresented = false
        showsReplaceRow = false
        showsGoToLineRow = false
        focusTarget = nil
        replaceAllSummary = nil
        refreshMatches()
        returnFocusToText()
    }

    func returnFocusToText() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    // MARK: - Commands

    func find(forward: Bool) {
        guard let textView, !query.isEmpty else { return }
        isFindBarPresented = true
        refreshMatches(immediately: true)
        if isSearching {
            pendingSearchAction = { [weak self] in self?.find(forward: forward) }
            return
        }
        guard !matches.isEmpty else {
            NSSound.beep()
            return
        }
        let index = CodeSearchEngine.adjacentMatchIndex(
            in: matches,
            from: textView.selectedRange(),
            forward: forward
        ) ?? 0
        select(matchAt: index)
    }

    func replaceCurrent() {
        guard let textView, isEditable, !query.isEmpty else { return }
        refreshMatches(immediately: true)
        if isSearching {
            pendingSearchAction = { [weak self] in self?.replaceCurrent() }
            return
        }
        guard let index = CodeSearchEngine.matchIndex(
            in: matches,
            equalTo: textView.selectedRange()
        ) else {
            find(forward: true)
            return
        }
        let match = matches[index]
        let replacement = CodeSearchEngine.replacement(
            for: match,
            in: textView.string,
            query: query,
            template: replacementText
        )
        textView.applyEdit(CodeEditorEdit(
            range: match,
            replacement: replacement,
            selection: NSRange(
                location: match.location + (replacement as NSString).length,
                length: 0
            )
        ))
        find(forward: true)
    }

    func replaceAll() {
        guard let textView, isEditable, !query.isEmpty, !hasInvalidRegularExpression, !isReplacingAll else { return }
        cancelReplacement()
        let text = textView.string
        let requestedQuery = query
        let template = replacementText
        let revision = textRevision
        let generation = replacementGeneration
        isReplacingAll = true
        replaceAllSummary = "正在替换…"
        replacementTask = Task { @MainActor [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                CodeSearchEngine.replacingAll(in: text, query: requestedQuery, template: template)
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, self.replacementGeneration == generation else { return }
            self.replacementTask = nil
            self.isReplacingAll = false
            guard self.textRevision == revision, self.query == requestedQuery, let textView = self.textView else {
                self.replaceAllSummary = "内容或查找条件已更改，请重新替换"
                return
            }
            guard result.count > 0 else {
                self.replaceAllSummary = "没有可替换的内容"
                NSSound.beep()
                return
            }
            // 整篇替换合并成一次撤销步骤，⌘Z 可以一次性还原全部替换。
            guard textView.applyEdit(CodeEditorEdit(
                range: NSRange(location: 0, length: (text as NSString).length),
                replacement: result.text,
                selection: NSRange(location: 0, length: 0)
            )) else { return }
            self.replaceAllSummary = "已替换 \(result.count) 处"
            self.refreshMatches()
            self.refreshEditingState()
        }
    }

    func toggleComment() {
        guard let textView, isEditable,
              let edit = CodeEditorTextTransform.toggleComment(
                in: textView.string,
                selection: textView.selectedRange()
              ) else { return }
        textView.applyEdit(edit)
    }

    func goToLine() {
        guard let textView,
              let line = Int(lineInput.trimmingCharacters(in: .whitespaces)),
              let range = CodeEditorTextTransform.range(in: textView.string, forLine: line) else {
            NSSound.beep()
            return
        }
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        showsGoToLineRow = false
        if findText.isEmpty, !showsReplaceRow { isFindBarPresented = false }
        returnFocusToText()
    }

    func undo() {
        guard let undoManager = textView?.undoManager, undoManager.canUndo else {
            NSSound.beep()
            return
        }
        undoManager.undo()
        refreshEditingState()
    }

    func redo() {
        guard let undoManager = textView?.undoManager, undoManager.canRedo else {
            NSSound.beep()
            return
        }
        undoManager.redo()
        refreshEditingState()
    }

    // MARK: - Private

    func refreshMatches(immediately: Bool = false) {
        guard let textView, isFindBarPresented, !query.isEmpty else {
            cancelSearch()
            matches = []
            matchedRevision = nil
            matchedQuery = nil
            matchCount = 0
            currentMatchNumber = nil
            currentMatchIndex = nil
            textView?.clearSearchHighlights()
            return
        }
        let requestedQuery = query
        if matchedRevision == textRevision, matchedQuery == requestedQuery {
            updateMatchSelection()
            return
        }
        if isSearching, pendingRevision == textRevision, pendingQuery == requestedQuery {
            return
        }
        cancelSearch()
        matches = []
        matchedRevision = nil
        matchedQuery = nil
        matchCount = 0
        currentMatchNumber = nil
        currentMatchIndex = nil
        textView.clearSearchHighlights()
        guard !hasInvalidRegularExpression else { return }
        let source = textView.string
        let revision = textRevision
        isSearching = true
        pendingRevision = revision
        pendingQuery = requestedQuery
        let generation = searchGeneration
        searchTask = Task { @MainActor [weak self] in
            if !immediately {
                do { try await Task.sleep(for: .milliseconds(120)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                CodeSearchEngine.matches(in: source, query: requestedQuery)
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, self.searchGeneration == generation else { return }
            self.searchTask = nil
            self.isSearching = false
            self.pendingRevision = nil
            self.pendingQuery = nil
            self.matches = result
            self.matchedRevision = revision
            self.matchedQuery = requestedQuery
            self.updateMatchSelection()
            let action = self.pendingSearchAction
            self.pendingSearchAction = nil
            action?()
        }
    }

    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration &+= 1
        isSearching = false
        pendingRevision = nil
        pendingQuery = nil
        pendingSearchAction = nil
    }

    private func cancelReplacement() {
        replacementTask?.cancel()
        replacementTask = nil
        replacementGeneration &+= 1
        isReplacingAll = false
    }

    private func updateMatchSelection() {
        guard let textView else { return }
        matchCount = matches.count
        currentMatchIndex = CodeSearchEngine.matchIndex(
            in: matches,
            equalTo: textView.selectedRange()
        )
        currentMatchNumber = currentMatchIndex.map { $0 + 1 }
        textView.applySearchHighlights(
            matches,
            current: currentMatchIndex.map { matches[$0] }
        )
    }

    private func select(matchAt index: Int) {
        guard let textView, matches.indices.contains(index) else { return }
        currentMatchIndex = index
        currentMatchNumber = index + 1
        textView.setSelectedRange(matches[index])
        textView.scrollRangeToVisible(matches[index])
        textView.applySearchHighlights(matches, current: matches[index])
    }
}

/// 主菜单命令的目标解析：只作用于当前获得键盘焦点的模块文本编辑器。
///
/// 没有聚焦的代码编辑器时，撤销与重做转发回响应链，普通输入框的撤销行为保持原样。
@MainActor
enum ModuleCodeEditorCommands {
    static var focusedController: ModuleCodeEditorController? {
        guard let textView = NSApp.keyWindow?.firstResponder as? CodeTextView else { return nil }
        return textView.editorController
    }

    static func undo() {
        guard let controller = focusedController else {
            NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
            return
        }
        controller.undo()
    }

    static func redo() {
        guard let controller = focusedController else {
            NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
            return
        }
        controller.redo()
    }

    static func presentFind(showsReplace: Bool = false) {
        focusedController?.presentFind(showsReplace: showsReplace)
    }

    static func find(forward: Bool) {
        focusedController?.find(forward: forward)
    }

    static func presentGoToLine() {
        focusedController?.presentGoToLine()
    }

    static func toggleComment() {
        focusedController?.toggleComment()
    }
}
