import SwiftUI

struct ModuleCodeSearchBar: View {
    @Bindable var controller: ModuleCodeEditorController
    @FocusState private var focusedField: ModuleCodeEditorFocusTarget?

    var body: some View {
        VStack(spacing: 6) {
            findRow
            if controller.showsReplaceRow { replaceRow }
            if controller.showsGoToLineRow { goToLineRow }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Design.Palette.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Design.Separator.color)
                .frame(height: 1)
        }
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
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("查找", text: $controller.findText)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .find)
                .onSubmit { controller.find(forward: true) }
                .frame(minWidth: 160, maxWidth: 280)
                .accessibilityIdentifier("moduleCodeFindField")
            Text(controller.matchSummary)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(controller.hasInvalidRegularExpression ? Design.Palette.warning : .secondary)
                .frame(minWidth: 84, alignment: .leading)
                .help("查找最多高亮前 5,000 处；全部替换会处理整篇文档。")
                .accessibilityIdentifier("moduleCodeMatchSummary")
            Button {
                controller.find(forward: false)
            } label: {
                Image(systemName: "chevron.up")
            }
            .help("查找上一个（⇧⌘G）")
            .accessibilityLabel("查找上一个")
            .disabled(controller.findText.isEmpty || controller.hasInvalidRegularExpression)
            Button {
                controller.find(forward: true)
            } label: {
                Image(systemName: "chevron.down")
            }
            .help("查找下一个（⌘G）")
            .accessibilityLabel("查找下一个")
            .disabled(controller.findText.isEmpty || controller.hasInvalidRegularExpression)
            Toggle("Aa", isOn: $controller.isCaseSensitive)
                .toggleStyle(.button)
                .help("区分大小写")
                .accessibilityLabel("区分大小写")
            Toggle(".*", isOn: $controller.usesRegularExpression)
                .toggleStyle(.button)
                .help("使用正则表达式")
                .accessibilityLabel("使用正则表达式")
            if controller.isEditable {
                Toggle(isOn: $controller.showsReplaceRow) {
                    Image(systemName: "arrow.2.squarepath")
                }
                .toggleStyle(.button)
                .help("显示替换（⌥⌘F）")
                .accessibilityLabel("显示替换")
            }
            Toggle(isOn: $controller.showsGoToLineRow) {
                Image(systemName: "arrow.right.to.line")
            }
            .toggleStyle(.button)
            .help("跳转到行（⌘L）")
            .accessibilityLabel("显示跳转到行")
            Spacer(minLength: 0)
            Button {
                controller.dismissFindBar()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .help("关闭查找栏（Esc）")
            .accessibilityLabel("关闭查找栏")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private var replaceRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.2.squarepath")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("替换为", text: $controller.replacementText)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .replace)
                .onSubmit { controller.replaceCurrent() }
                .frame(minWidth: 160, maxWidth: 280)
                .accessibilityIdentifier("moduleCodeReplaceField")
            Button("替换") { controller.replaceCurrent() }
                .buttonStyle(.bordered)
                .disabled(controller.findText.isEmpty || controller.hasInvalidRegularExpression || controller.isReplacingAll)
            Button("全部替换") { controller.replaceAll() }
                .buttonStyle(.bordered)
                .disabled(controller.findText.isEmpty || controller.hasInvalidRegularExpression || controller.isReplacingAll)
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
        HStack(spacing: 6) {
            Image(systemName: "number")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("行号", text: $controller.lineInput)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .line)
                .onSubmit { controller.goToLine() }
                .frame(width: 96)
                .accessibilityIdentifier("moduleCodeGoToLineField")
            Button("跳转") { controller.goToLine() }
                .buttonStyle(.bordered)
                .disabled(controller.lineInput.trimmingCharacters(in: .whitespaces).isEmpty)
            Text("共 \(controller.lineCount) 行")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }
}

struct ModuleCodeEditorToolbar: View {
    let controller: ModuleCodeEditorController

    var body: some View {
        HStack(spacing: 2) {
            Button {
                controller.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 24, height: 22)
            }
            .help("撤销（⌘Z）")
            .disabled(!controller.canUndo)
            .accessibilityIdentifier("moduleCodeUndoButton")

            Button {
                controller.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .frame(width: 24, height: 22)
            }
            .help("重做（⇧⌘Z）")
            .disabled(!controller.canRedo)
            .accessibilityIdentifier("moduleCodeRedoButton")

            Button {
                controller.presentFind()
            } label: {
                Image(systemName: "magnifyingglass")
                    .frame(width: 24, height: 22)
            }
            .help("查找与替换（⌘F）")
            .accessibilityIdentifier("moduleCodeFindButton")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }
}
