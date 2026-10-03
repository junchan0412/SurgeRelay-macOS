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
    @State private var loadErrorMessage: String?
    @State private var cursorPosition = ModuleCodeCursorPosition(line: 1, column: 1)
    @State private var showsComparison = false
    @State private var confirmsRestore = false
    @State private var editor = ModuleCodeEditorController()
    @State private var recoveredDraft = false
    @State private var draftBaseHasChanged = false
    @State private var showsDraftComparison = false
    @State private var showsVersionHistory = false
    @State private var confirmsDraftOverwrite = false
    @State private var pendingOverwriteBase: String?

    private var currentModule: RelayModule {
        model.modules.first(where: { $0.id == module.id }) ?? module
    }

    private var reloadToken: String {
        let module = currentModule
        return [
            module.id.uuidString,
            module.sourceURL,
            module.contentHash ?? "",
            module.state.rawValue,
            module.lastUpdatedAt.map { String($0.timeIntervalSinceReferenceDate) } ?? "",
            module.lastError ?? ""
        ].joined(separator: "|")
    }

    var body: some View {
        VStack(spacing: 0) {
            if currentModule.hasOverrideConflict {
                HStack(spacing: 10) {
                    Label("上游内容已变化，请确认本地编辑", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Design.Palette.warning)
                    Spacer()
                    Button("比较…") { showsComparison = true }
                    Button("保留本地编辑") {
                        Task { await model.acceptOverrideConflict(moduleID: module.id) }
                    }
                }
                .padding(10)
                .background(Design.Palette.warning.opacity(0.08))
                Divider()
            }
            if recoveredDraft || draftBaseHasChanged {
                HStack {
                    Text(draftBaseHasChanged ? "草稿的已保存版本发生变化，保存前请比较并确认覆盖。" : "已恢复上次未保存的草稿。")
                        .font(.caption)
                    Spacer()
                    Button("比较…") { showsDraftComparison = true }
                }
                .padding(10)
                .background(Design.Palette.warning.opacity(0.08))
            }
            if let message = model.previewDraftPersistenceError {
                Text("草稿尚未写入磁盘：\(message)")
                    .font(.caption)
                    .foregroundStyle(Design.Palette.warning)
                    .padding(10)
            }
            if CodeTextView.usesPlainTextMode(text) {
                Text("大文件模式：纯文本，不自动折行；查找、替换与撤销仍可用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            if editor.isFindBarPresented {
                ModuleCodeSearchBar(controller: editor)
            }
            ZStack {
                ScrollView(CodeTextView.usesPlainTextMode(text) ? [.horizontal, .vertical] : .vertical) {
                    ModuleCodeTextView(
                        text: $text,
                        isEditable: !isLoading,
                        modules: [currentModule],
                        selectedModuleID: module.id,
                        controller: editor,
                        onCursorPositionChange: { cursorPosition = $0 }
                    )
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .onScrollGeometryChange(for: CGRect.self) { geometry in
                    geometry.visibleRect
                } action: { _, viewport in
                    editor.updateViewport(viewport)
                }
                .background(Design.Palette.canvas)
                if isLoading {
                    ProgressView("正在载入模块内容…")
                        .padding(16)
                        .background(Design.Palette.surface, in: RoundedRectangle(cornerRadius: 8))
                } else if text.isEmpty, let loadErrorMessage {
                    ContentUnavailableView {
                        Label("暂时无法显示模块内容", systemImage: "doc.text.magnifyingglass")
                    } description: {
                        Text(loadErrorMessage)
                    } actions: {
                        Button("重试") { Task { await load(force: true) } }
                    }
                }
            }

            Divider()
            HStack(spacing: 12) {
                Label("第 \(cursorPosition.line) 行，第 \(cursorPosition.column) 列", systemImage: "text.cursor")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("版本…") { showsVersionHistory = true }
                ModuleCodeEditorToolbar(controller: editor)
                Button("恢复") { confirmsRestore = true }
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
        .task(id: reloadToken) { await load() }
        .onChange(of: text) { _, _ in retainDraft() }
        .onDisappear {
            retainDraft()
            Task { await model.flushPreviewDrafts() }
        }
        .confirmationDialog("恢复转换结果？", isPresented: $confirmsRestore) {
            Button("恢复转换结果", role: .destructive) { restore() }
        } message: { Text("当前模块的手动修改会被丢弃。") }
        .sheet(isPresented: $showsVersionHistory) {
            ModuleVersionHistoryView(moduleID: module.id).environment(model)
        }
        .sheet(isPresented: $showsDraftComparison) {
            OverrideComparisonView(module: currentModule, draftText: text).environment(model)
        }
        .confirmationDialog("已保存内容已变化，覆盖为草稿？", isPresented: $confirmsDraftOverwrite) {
            Button("覆盖为草稿", role: .destructive) { write(approvedBase: pendingOverwriteBase) }
            Button("比较…") { showsDraftComparison = true }
        } message: {
            Text("草稿基于较早版本。覆盖会替换当前已保存内容，并按现有发布设置刷新输出。")
        }
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

    private func load(force: Bool = false) async {
        guard !isWriting else { return }
        if !force, let draft = model.modulePreviewDrafts[module.id] {
            text = draft.text
            savedText = draft.savedText
            recoveredDraft = model.restoredPreviewDraftIDs.remove(module.id) != nil || recoveredDraft
            isLoading = false
            do {
                let current = try await model.previewContent(for: currentModule)
                try Task.checkCancellation()
                guard savedText.utf16.elementsEqual(draft.savedText.utf16) else { return }
                draftBaseHasChanged = draft.hasBaseChanged(comparedTo: current)
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = "草稿已保留，但无法核验当前版本：\(error.localizedDescription)"
            }
            return
        }
        guard force || text == savedText else { return }
        isLoading = true
        defer {
            if !Task.isCancelled { isLoading = false }
        }
        let latestModule = currentModule
        do {
            let content = try await model.previewContent(for: latestModule)
            try Task.checkCancellation()
            text = content
            savedText = content
            loadErrorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            loadErrorMessage = latestModule.state == .updating
                ? "模块正在更新，完成后将自动显示内容。"
                : "无法预览转换结果：\(error.localizedDescription)"
        }
    }

    private func write(approvedBase: String? = nil) {
        isWriting = true
        let submittedText = text
        let base = savedText
        Task {
            defer { isWriting = false }
            do {
                let current = try await model.previewContent(for: currentModule)
                let draft = ModulePreviewDraft(text: submittedText, savedText: base)
                if draft.hasBaseChanged(comparedTo: current),
                   approvedBase?.utf16.elementsEqual(current.utf16) != true {
                    draftBaseHasChanged = true
                    pendingOverwriteBase = current
                    confirmsDraftOverwrite = true
                    return
                }
                let writtenContent = try await model.savePreviewContent(
                    submittedText, for: currentModule, expectedContentHash: Data(current.utf8).sha256String
                )
                if text.utf16.elementsEqual(submittedText.utf16) { text = writtenContent.content }
                savedText = writtenContent.content
                recoveredDraft = false
                draftBaseHasChanged = false
                pendingOverwriteBase = nil
                retainDraft()
                await model.flushPreviewDrafts()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func restore() {
        isWriting = true
        let submittedText = text
        Task {
            defer { isWriting = false }
            do {
                let restored = try await model.restorePreviewContent(for: currentModule)
                if text.utf16.elementsEqual(submittedText.utf16) { text = restored }
                savedText = restored
                recoveredDraft = false
                draftBaseHasChanged = false
                retainDraft()
                await model.flushPreviewDrafts()
                loadErrorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func retainDraft() {
        guard model.modules.contains(where: { $0.id == module.id }) else { return }
        guard !isLoading else { return }
        if text.utf16.elementsEqual(savedText.utf16) { model.modulePreviewDrafts.removeValue(forKey: module.id) }
        else { model.modulePreviewDrafts[module.id] = ModulePreviewDraft(text: text, savedText: savedText) }
    }
}

private struct OverrideComparisonView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let module: RelayModule
    var draftText: String? = nil
    @State private var upstream = ""
    @State private var local = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(draftText == nil ? "上游与本地编辑" : "已保存内容与草稿").font(.headline)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            HSplitView {
                comparisonColumn(draftText == nil ? "最新上游" : "当前已保存内容", text: upstream)
                comparisonColumn(draftText == nil ? "当前本地编辑" : "未保存草稿", text: local)
            }
        }
        .frame(minWidth: 920, minHeight: 560)
        .task {
            do {
                if let draftText {
                    upstream = try await model.previewContent(for: module)
                    local = draftText
                } else {
                    async let upstreamValue = model.convertedPreviewContent(for: module)
                    async let localValue = model.previewContent(for: module)
                    (upstream, local) = try await (upstreamValue, localValue)
                }
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
    @State private var editor = ModuleCodeEditorController()

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
        VStack(spacing: 0) {
            if CodeTextView.usesPlainTextMode(text) {
                Text("大文件模式：纯文本，不自动折行；仍可查找与拷贝完整内容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            if editor.isFindBarPresented {
                ModuleCodeSearchBar(controller: editor)
            }
            ScrollView(CodeTextView.usesPlainTextMode(text) ? [.horizontal, .vertical] : .vertical) {
                ModuleCodeTextView(
                    text: .constant(text),
                    isEditable: false,
                    modules: enabledModules,
                    selectedModuleID: nil,
                    controller: editor
                )
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onScrollGeometryChange(for: CGRect.self) { geometry in
                geometry.visibleRect
            } action: { _, viewport in
                editor.updateViewport(viewport)
            }
            .background(Design.Palette.canvas)
        }
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

/// 独立文本编辑器：直接编辑单个模块转换后的文本内容。
struct ModuleTextEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let module: RelayModule
    @State private var text = ""
    @State private var savedText = ""
    @State private var isLoading = true
    @State private var isWriting = false
    @State private var errorMessage: String?
    @State private var loadErrorMessage: String?
    @State private var cursorPosition = ModuleCodeCursorPosition(line: 1, column: 1)
    @State private var editor = ModuleCodeEditorController()
    @State private var recoveredDraft = false
    @State private var draftBaseHasChanged = false
    @State private var showsDraftComparison = false
    @State private var showsVersionHistory = false
    @State private var confirmsDraftOverwrite = false
    @State private var pendingOverwriteBase: String?

    private var currentModule: RelayModule {
        model.modules.first(where: { $0.id == module.id }) ?? module
    }

    private var reloadToken: String {
        let module = currentModule
        return [
            module.id.uuidString,
            module.sourceURL,
            module.contentHash ?? "",
            module.state.rawValue,
            module.lastUpdatedAt.map { String($0.timeIntervalSinceReferenceDate) } ?? "",
            module.lastError ?? ""
        ].joined(separator: "|")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("文本编辑：\(currentModule.name)")
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("版本…") { showsVersionHistory = true }
                ModuleCodeEditorToolbar(controller: editor)
                Button("恢复") { restore() }
                    .disabled(isWriting || isLoading)
                Button("保存") { write() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(isWriting || isLoading || text == savedText)
                // 不给“完成”绑定 return：编辑器聚焦时 return 必须落到文本里换行。
                Button("完成") { dismiss() }
                    .keyboardShortcut("w", modifiers: .command)
            }
            .padding(12)
            Divider()
            if recoveredDraft || draftBaseHasChanged {
                HStack {
                    Text(draftBaseHasChanged ? "草稿的已保存版本发生变化，保存前请比较并确认覆盖。" : "已恢复上次未保存的草稿。")
                        .font(.caption)
                    Spacer()
                    Button("比较…") { showsDraftComparison = true }
                }
                .padding(10)
                .background(Design.Palette.warning.opacity(0.08))
            }
            if let message = model.previewDraftPersistenceError {
                Text("草稿尚未写入磁盘：\(message)")
                    .font(.caption)
                    .foregroundStyle(Design.Palette.warning)
                    .padding(10)
            }
            if CodeTextView.usesPlainTextMode(text) {
                Text("大文件模式：纯文本，不自动折行；查找、替换与撤销仍可用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            if editor.isFindBarPresented {
                ModuleCodeSearchBar(controller: editor)
            }
            ZStack {
                ScrollView(CodeTextView.usesPlainTextMode(text) ? [.horizontal, .vertical] : .vertical) {
                    ModuleCodeTextView(
                        text: $text,
                        isEditable: !isLoading,
                        modules: [currentModule],
                        selectedModuleID: module.id,
                        controller: editor,
                        onCursorPositionChange: { cursorPosition = $0 }
                    )
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .onScrollGeometryChange(for: CGRect.self) { geometry in
                    geometry.visibleRect
                } action: { _, viewport in
                    editor.updateViewport(viewport)
                }
                .background(Design.Palette.canvas)
                if isLoading {
                    ProgressView("正在载入模块内容…")
                        .padding(16)
                        .background(Design.Palette.surface, in: RoundedRectangle(cornerRadius: 8))
                } else if text.isEmpty, let loadErrorMessage {
                    ContentUnavailableView {
                        Label("暂时无法显示模块内容", systemImage: "doc.text.magnifyingglass")
                    } description: {
                        Text(loadErrorMessage)
                    } actions: {
                        Button("重试") { Task { await load(force: true) } }
                    }
                }
            }
            HStack(spacing: 8) {
                Label("第 \(cursorPosition.line) 行，第 \(cursorPosition.column) 列", systemImage: "text.cursor")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if !isLoading, text != savedText {
                    Label("有尚未写入的修改", systemImage: "square.and.pencil")
                        .font(.caption)
                        .foregroundStyle(Design.Palette.warning)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(minWidth: 680, minHeight: 480)
        .task(id: reloadToken) { await load() }
        .onChange(of: text) { _, _ in retainDraft() }
        .onDisappear {
            retainDraft()
            Task { await model.flushPreviewDrafts() }
        }
        .sheet(isPresented: $showsVersionHistory) {
            ModuleVersionHistoryView(moduleID: module.id).environment(model)
        }
        .sheet(isPresented: $showsDraftComparison) {
            OverrideComparisonView(module: currentModule, draftText: text).environment(model)
        }
        .confirmationDialog("已保存内容已变化，覆盖为草稿？", isPresented: $confirmsDraftOverwrite) {
            Button("覆盖为草稿", role: .destructive) { write(approvedBase: pendingOverwriteBase) }
            Button("比较…") { showsDraftComparison = true }
        } message: {
            Text("草稿基于较早版本。覆盖会替换当前已保存内容，并按现有发布设置刷新输出。")
        }
        .alert("无法完成操作", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func load(force: Bool = false) async {
        guard !isWriting else { return }
        if !force, let draft = model.modulePreviewDrafts[module.id] {
            text = draft.text
            savedText = draft.savedText
            recoveredDraft = model.restoredPreviewDraftIDs.remove(module.id) != nil || recoveredDraft
            isLoading = false
            do {
                let current = try await model.previewContent(for: currentModule)
                try Task.checkCancellation()
                guard savedText.utf16.elementsEqual(draft.savedText.utf16) else { return }
                draftBaseHasChanged = draft.hasBaseChanged(comparedTo: current)
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = "草稿已保留，但无法核验当前版本：\(error.localizedDescription)"
            }
            return
        }
        guard force || text == savedText else { return }
        isLoading = true
        defer {
            if !Task.isCancelled { isLoading = false }
        }
        let latestModule = currentModule
        do {
            let content = try await model.previewContent(for: latestModule)
            try Task.checkCancellation()
            text = content
            savedText = content
            loadErrorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            loadErrorMessage = latestModule.state == .updating
                ? "模块正在更新，完成后将自动显示内容。"
                : "无法读取模块内容：\(error.localizedDescription)"
        }
    }

    private func write(approvedBase: String? = nil) {
        isWriting = true
        let submittedText = text
        let base = savedText
        Task {
            defer { isWriting = false }
            do {
                let current = try await model.previewContent(for: currentModule)
                let draft = ModulePreviewDraft(text: submittedText, savedText: base)
                if draft.hasBaseChanged(comparedTo: current),
                   approvedBase?.utf16.elementsEqual(current.utf16) != true {
                    draftBaseHasChanged = true
                    pendingOverwriteBase = current
                    confirmsDraftOverwrite = true
                    return
                }
                let writtenContent = try await model.savePreviewContent(
                    submittedText, for: currentModule, expectedContentHash: Data(current.utf8).sha256String
                )
                if text.utf16.elementsEqual(submittedText.utf16) { text = writtenContent.content }
                savedText = writtenContent.content
                recoveredDraft = false
                draftBaseHasChanged = false
                pendingOverwriteBase = nil
                retainDraft()
                await model.flushPreviewDrafts()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func restore() {
        isWriting = true
        let submittedText = text
        Task {
            defer { isWriting = false }
            do {
                let restored = try await model.restorePreviewContent(for: currentModule)
                if text.utf16.elementsEqual(submittedText.utf16) { text = restored }
                savedText = restored
                recoveredDraft = false
                draftBaseHasChanged = false
                retainDraft()
                await model.flushPreviewDrafts()
                loadErrorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
    private func retainDraft() {
        guard model.modules.contains(where: { $0.id == module.id }) else { return }
        guard !isLoading else { return }
        if text.utf16.elementsEqual(savedText.utf16) { model.modulePreviewDrafts.removeValue(forKey: module.id) }
        else { model.modulePreviewDrafts[module.id] = ModulePreviewDraft(text: text, savedText: savedText) }
    }

}
