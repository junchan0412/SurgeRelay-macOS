import SwiftUI

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
            module.outputFormat.rawValue,
            module.contentHash ?? "",
            module.state.rawValue,
            module.lastUpdatedAt.map { String($0.timeIntervalSinceReferenceDate) } ?? "",
            module.lastError ?? ""
        ].joined(separator: "|")
    }

    var body: some View {
        VStack(spacing: 0) {
            editorTopBar

            if currentModule.hasOverrideConflict {
                HStack(spacing: 10) {
                    Label("上游内容已变化，请确认是否保留本地编辑", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Design.Palette.warning)
                    Spacer()
                    Button("对比差异…") { showsComparison = true }
                        .controlSize(.small)
                    Button("保留本地编辑") {
                        Task { await model.acceptOverrideConflict(moduleID: module.id) }
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Design.Palette.warning.opacity(0.09))
                Divider()
            }

            if recoveredDraft || draftBaseHasChanged {
                HStack(spacing: 10) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .foregroundStyle(Design.Palette.warning)
                    Text(draftBaseHasChanged ? "草稿基线已变化，保存前请比较并确认覆盖。" : "已恢复上次未保存的草稿。")
                        .font(.system(size: 12))
                    Spacer()
                    Button("比较…") { showsDraftComparison = true }
                        .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Design.Palette.warning.opacity(0.08))
                Divider()
            }

            if let message = model.previewDraftPersistenceError {
                Text("草稿尚未写入磁盘：\(message)")
                    .font(.caption)
                    .foregroundStyle(Design.Palette.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Design.Palette.warning.opacity(0.08))
            }

            if CodeTextView.usesPlainTextMode(text) {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.horizontal")
                    Text("大文件纯文本模式：关闭自动折行与实时着色以保障流畅编辑；查找、替换与撤销正常可用。")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Design.Palette.elevated.opacity(0.6))
                Divider()
            }

            if editor.isFindBarPresented {
                ModuleCodeSearchBar(controller: editor)
            }

            ZStack {
                ScrollView(CodeTextView.usesPlainTextMode(text) ? [.horizontal, .vertical] : .vertical) {
                    ModuleCodeTextView(
                        text: $text,
                        isEditable: !isLoading && !model.isWorkspaceTransitioning,
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
                .background(Design.Palette.codeBackground)

                if isLoading {
                    ProgressView("正在载入模块内容…")
                        .padding(16)
                        .background(Design.Palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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

            editorBottomStatusBar
        }
        .task(id: reloadToken) { await load() }
        .onChange(of: text) { _, _ in retainDraft() }
        .onDisappear {
            retainDraft()
            Task { await model.flushPreviewDrafts() }
        }
        .confirmationDialog("恢复转换结果？", isPresented: $confirmsRestore) {
            Button("恢复转换结果", role: .destructive) { restore() }
        } message: {
            Text("当前模块的手动修改会被丢弃。")
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
        .sheet(isPresented: $showsComparison) {
            OverrideComparisonView(module: currentModule)
                .environment(model)
        }
    }

    private var editorTopBar: some View {
        HStack(spacing: 10) {
            MetadataPill(currentModule.outputFormat.title, tint: Design.Palette.accent)
            Text(currentModule.publishedRelativePath)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !isLoading, text != savedText {
                MetadataPill("未保存修改", systemImage: "circle.fill", tint: Design.Palette.warning)
            }
            Spacer(minLength: 4)
            ModuleCodeEditorToolbar(controller: editor)
            Divider().frame(height: 16)
            TextCopyButton(text: text, title: "拷贝全文")
            Button("版本…") { showsVersionHistory = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button("恢复默认") { confirmsRestore = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isWriting || isLoading)
            Button("保存") { write() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isWriting || isLoading || text == savedText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Design.Palette.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Design.Separator.color)
                .frame(height: 1)
        }
    }

    private var editorBottomStatusBar: some View {
        HStack(spacing: 12) {
            Label("第 \(cursorPosition.line) 行，第 \(cursorPosition.column) 列", systemImage: "text.cursor")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if !text.isEmpty {
                Text(ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .file))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Design.Palette.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Design.Separator.color)
                .frame(height: 1)
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
                    submittedText,
                    for: currentModule,
                    expectedContentHash: Data(current.utf8).sha256String
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
            SheetHeader(
                draftText == nil ? "上游与本地编辑对比" : "已保存版本与未保存草稿对比",
                subtitle: module.name,
                systemImage: "arrow.left.arrow.right"
            )
            HSplitView {
                comparisonColumn(draftText == nil ? "最新上游转换结果" : "当前已保存内容", text: upstream)
                comparisonColumn(draftText == nil ? "当前本地编辑" : "未保存草稿", text: local)
            }
            SheetActionFooter {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
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
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Design.Palette.surface)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background(Design.Palette.codeBackground)
        }
    }
}

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
            module.outputFormat.rawValue,
            module.contentHash ?? "",
            module.state.rawValue,
            module.lastUpdatedAt.map { String($0.timeIntervalSinceReferenceDate) } ?? "",
            module.lastError ?? ""
        ].joined(separator: "|")
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                currentModule.name,
                subtitle: "\(currentModule.outputFormat.title) · \(currentModule.publishedRelativePath)",
                systemImage: "curlybraces"
            ) {
                HStack(spacing: 8) {
                    ModuleCodeEditorToolbar(controller: editor)
                    Button("版本…") { showsVersionHistory = true }
                        .controlSize(.small)
                    Button("恢复默认") { restore() }
                        .controlSize(.small)
                        .disabled(isWriting || isLoading)
                    Button("保存") { write() }
                        .keyboardShortcut("s", modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isWriting || isLoading || text == savedText)
                    Button("完成") { dismiss() }
                        .controlSize(.small)
                        .keyboardShortcut("w", modifiers: .command)
                }
            }

            if recoveredDraft || draftBaseHasChanged {
                HStack {
                    Text(draftBaseHasChanged ? "草稿的已保存版本发生变化，保存前请比较并确认覆盖。" : "已恢复上次未保存的草稿。")
                        .font(.caption)
                    Spacer()
                    Button("比较…") { showsDraftComparison = true }
                        .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Design.Palette.warning.opacity(0.08))
                Divider()
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
                        isEditable: !isLoading && !model.isWorkspaceTransitioning,
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
                .background(Design.Palette.codeBackground)
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
                    MetadataPill("未保存修改", systemImage: "circle.fill", tint: Design.Palette.warning)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Design.Palette.surface)
            .overlay(alignment: .top) {
                Rectangle().fill(Design.Separator.color).frame(height: 1)
            }
        }
        .frame(minWidth: 740, minHeight: 520)
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
                    submittedText,
                    for: currentModule,
                    expectedContentHash: Data(current.utf8).sha256String
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
