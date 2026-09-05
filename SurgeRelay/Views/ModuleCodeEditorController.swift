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

    @ObservationIgnored private(set) weak var textView: CodeTextView?
    @ObservationIgnored private var matches: [NSRange] = []
    @ObservationIgnored private var currentMatchIndex: Int?

    var query: CodeSearchQuery {
        CodeSearchQuery(
            text: findText,
            isCaseSensitive: isCaseSensitive,
            usesRegularExpression: usesRegularExpression
        )
    }

    var matchSummary: String {
        CodeSearchEngine.regularExpressionErrorMessage(for: query)
            ?? (query.isEmpty ? "" : CodeSearchEngine.matchSummary(
                matchCount: matchCount,
                currentNumber: currentMatchNumber
            ))
    }

    var hasInvalidRegularExpression: Bool {
        CodeSearchEngine.regularExpressionErrorMessage(for: query) != nil
    }

    var lineCount: Int {
        textView.map { CodeEditorTextTransform.lineCount(in: $0.string) } ?? 1
    }

    // MARK: - Text view binding

    func attach(_ textView: CodeTextView) {
        self.textView = textView
        textView.editorController = self
        refreshEditingState()
        refreshMatches()
    }

    func setEditable(_ isEditable: Bool) {
        guard self.isEditable != isEditable else { return }
        self.isEditable = isEditable
        if !isEditable { showsReplaceRow = false }
    }

    /// 文本或选区变化后同步匹配结果和撤销状态。
    func textDidChange() {
        replaceAllSummary = nil
        refreshMatches()
        refreshEditingState()
    }

    func selectionDidChange() {
        guard isFindBarPresented, !matches.isEmpty, let textView else { return }
        if let index = CodeSearchEngine.matchIndex(in: matches, equalTo: textView.selectedRange()) {
            currentMatchIndex = index
            currentMatchNumber = index + 1
            textView.applySearchHighlights(matches, current: matches[index])
        }
    }

    func refreshEditingState() {
        let undoManager = textView?.undoManager
        canUndo = undoManager?.canUndo ?? false
        canRedo = undoManager?.canRedo ?? false
    }

    /// 载入新内容后重置查找结果与撤销历史。
    func resetForReloadedContent() {
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
        isFindBarPresented = false
        showsReplaceRow = false
        showsGoToLineRow = false
        focusTarget = nil
        replaceAllSummary = nil
        textView?.clearSearchHighlights()
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
        refreshMatches()
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
        refreshMatches()
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
        refreshMatches()
        find(forward: true)
    }

    func replaceAll() {
        guard let textView, isEditable, !query.isEmpty else { return }
        let text = textView.string
        let result = CodeSearchEngine.replacingAll(in: text, query: query, template: replacementText)
        guard result.count > 0 else {
            replaceAllSummary = "没有可替换的内容"
            NSSound.beep()
            return
        }
        // 整篇替换合并成一次撤销步骤，⌘Z 可以一次性还原全部替换。
        textView.applyEdit(CodeEditorEdit(
            range: NSRange(location: 0, length: (text as NSString).length),
            replacement: result.text,
            selection: NSRange(location: 0, length: 0)
        ))
        replaceAllSummary = "已替换 \(result.count) 处"
        refreshMatches()
        refreshEditingState()
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

    func refreshMatches() {
        guard let textView, isFindBarPresented, !query.isEmpty else {
            matches = []
            matchCount = 0
            currentMatchNumber = nil
            currentMatchIndex = nil
            textView?.clearSearchHighlights()
            return
        }
        matches = CodeSearchEngine.matches(in: textView.string, query: query)
        matchCount = matches.count
        if matches.isEmpty {
            currentMatchIndex = nil
        } else if let index = CodeSearchEngine.matchIndex(
            in: matches,
            equalTo: textView.selectedRange()
        ) {
            currentMatchIndex = index
        } else if let existing = currentMatchIndex, existing >= matches.count {
            currentMatchIndex = matches.count - 1
        }
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
