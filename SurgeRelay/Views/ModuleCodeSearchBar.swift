import SwiftUI

/// 模块文本编辑器的查找 / 替换 / 跳转栏。
///
/// 这里刻意用 SwiftUI 实现而不是 `NSTextView` 自带的 find bar：编辑器为了绕开
/// SwiftUI 承载 `NSScrollView` 的合成缺陷没有放进 `NSScrollView`，而系统 find bar
/// 必须依附 `NSScrollView` 才能显示。
struct ModuleCodeSearchBar: View {
    @Bindable var controller: ModuleCodeEditorController
    @FocusState private var focusedField: ModuleCodeEditorFocusTarget?

    var body: some View {
        VStack(spacing: 6) {
            findRow
            if controller.showsReplaceRow { replaceRow }
            if controller.showsGoToLineRow { goToLineRow }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onChange(of: controller.focusTarget) { _, target in
            guard let target else { return }
            focusedField = target
            controller.focusTarget = nil
        }
        .onChange(of: controller.findText) { controller.refreshMatches() }
        .onChange(of: controller.isCaseSensitive) { controller.refreshMatches() }
        .onChange(of: controller.usesRegularExpression) { controller.refreshMatches() }
        .onExitCommand { controller.dismissFindBar() }
    }

    private var findRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("查找", text: $controller.findText)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .find)
                .onSubmit { controller.find(forward: true) }
                .frame(minWidth: 140)
                .accessibilityIdentifier("moduleCodeFindField")
            Text(controller.matchSummary)
                .font(.caption.monospacedDigit())
                .foregroundStyle(controller.hasInvalidRegularExpression ? .orange : .secondary)
                .frame(minWidth: 84, alignment: .leading)
            Button {
                controller.find(forward: false)
            } label: {
                Image(systemName: "chevron.up")
            }
            .help("查找上一个（⇧⌘G）")
            .disabled(controller.findText.isEmpty)
            Button {
                controller.find(forward: true)
            } label: {
                Image(systemName: "chevron.down")
            }
            .help("查找下一个（⌘G）")
            .disabled(controller.findText.isEmpty)
            Toggle("Aa", isOn: $controller.isCaseSensitive)
                .toggleStyle(.button)
                .help("区分大小写")
            Toggle(".*", isOn: $controller.usesRegularExpression)
                .toggleStyle(.button)
                .help("使用正则表达式")
            if controller.isEditable {
                Toggle(isOn: $controller.showsReplaceRow) {
                    Image(systemName: "arrow.2.squarepath")
                }
                .toggleStyle(.button)
                .help("显示替换（⌥⌘F）")
            }
            Toggle(isOn: $controller.showsGoToLineRow) {
                Image(systemName: "arrow.right.to.line")
            }
            .toggleStyle(.button)
            .help("跳转到行（⌘L）")
            Spacer(minLength: 0)
            Button {
                controller.dismissFindBar()
            } label: {
                Image(systemName: "xmark")
            }
            .help("关闭查找栏（esc）")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private var replaceRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.2.squarepath")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("替换为", text: $controller.replacementText)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .replace)
                .onSubmit { controller.replaceCurrent() }
                .frame(minWidth: 140)
                .accessibilityIdentifier("moduleCodeReplaceField")
            Button("替换") { controller.replaceCurrent() }
                .disabled(controller.findText.isEmpty)
            Button("全部替换") { controller.replaceAll() }
                .disabled(controller.findText.isEmpty)
            if let summary = controller.replaceAllSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    private var goToLineRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "number")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("行号", text: $controller.lineInput)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .line)
                .onSubmit { controller.goToLine() }
                .frame(width: 96)
                .accessibilityIdentifier("moduleCodeGoToLineField")
            Button("跳转") { controller.goToLine() }
                .disabled(controller.lineInput.trimmingCharacters(in: .whitespaces).isEmpty)
            Text("共 \(controller.lineCount) 行")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }
}

/// 编辑器常用命令的紧凑按钮组，让撤销、重做和查找在界面上可见而不只依赖快捷键。
struct ModuleCodeEditorToolbar: View {
    let controller: ModuleCodeEditorController

    var body: some View {
        HStack(spacing: 4) {
            Button {
                controller.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .help("撤销（⌘Z）")
            .disabled(!controller.canUndo)
            .accessibilityIdentifier("moduleCodeUndoButton")
            Button {
                controller.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .help("重做（⇧⌘Z）")
            .disabled(!controller.canRedo)
            .accessibilityIdentifier("moduleCodeRedoButton")
            Button {
                controller.presentFind()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .help("查找与替换（⌘F）")
            .accessibilityIdentifier("moduleCodeFindButton")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }
}
