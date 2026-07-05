import SwiftUI

struct ModuleEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let module: RelayModule?
    @State private var draft: ModuleDraft
    @State private var localError: String?
    @State private var isAdvancedExpanded: Bool
    @State private var nameLookup: Task<Void, Never>?
    @State private var showsNewFolderDialog = false
    @State private var newFolderName = ""

    private var isNativeSurgeModule: Bool {
        guard let url = URL(string: draft.sourceURL), !draft.sourceURL.isEmpty else {
            return draft.sourceFormat == .surge
        }
        return draft.sourceFormat.isNativeSurgeModule(for: url)
    }

    private var customIconPreviewURL: URL? {
        let value = draft.iconURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased()),
              url.host?.isEmpty == false else { return nil }
        return url
    }

    private var hasCustomIconInput: Bool {
        !draft.iconURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var customIconInputIsInvalid: Bool {
        hasCustomIconInput && customIconPreviewURL == nil
    }

    private var iconURLHint: String {
        if customIconInputIsInvalid {
            return "请输入完整的 HTTP/HTTPS 图标地址。"
        }
        return "留空时优先展示来源里的 #!icon；自定义图标只用于 Surge Relay 与 Web 管理，不写入 Surge 输出。"
    }

    init(module: RelayModule?) {
        self.module = module
        _draft = State(initialValue: module.map(ModuleDraft.init(module:)) ?? ModuleDraft())
        _isAdvancedExpanded = State(initialValue: module.map { $0.scriptHubOptions != ScriptHubOptions() } ?? false)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(module == nil ? "添加模块" : "编辑模块").font(.title2.bold())
                    Text("原始地址可以随时修改，已发布的稳定地址不会改变。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    editorPreviewCard
                    basicInfoSection
                    iconSection
                    publishingSection
                    sourceSection
                    advancedEditorSection
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 30)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.visible)
            .task {
                if module == nil,
                   !model.settings.publishToGitHub,
                   model.settings.publishToLocal {
                    draft.storageLocation = .local
                }
                await model.refreshModuleOutputFolders()
            }
            .onChange(of: draft.sourceURL) { _, newValue in
                autofillName(from: newValue)
            }

            SheetActionFooter {
                Button("取消", role: .cancel) { dismiss() }
                Spacer()
                Button(module == nil ? "添加" : "保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 620, height: 700)
        .alert("无法保存", isPresented: Binding(
            get: { localError != nil },
            set: { if !$0 { localError = nil } }
        )) {
            Button("好", role: .cancel) { localError = nil }
        } message: {
            Text(localError ?? "")
        }
        .alert("新建存放文件夹", isPresented: $showsNewFolderDialog) {
            TextField("文件夹名称", text: $newFolderName)
            Button("创建") { createFolder() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(model.settings.publishToLocal
                ? "将在本地模块根目录下创建文件夹。"
                : "GitHub 不支持空文件夹；该路径会先保存为选项，发布模块时自动创建。")
        }
    }

    private var editorPreviewTitle: String {
        let value = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "未命名模块" : value
    }

    private var editorPreviewSubtitle: String {
        var parts = [draft.storageLocation.title, draftSourceOrigin.title]
        let category = draft.category.trimmingCharacters(in: .whitespacesAndNewlines)
        if !category.isEmpty { parts.append(category) }
        if !draft.publishesStandalone { parts.append("不发布独立模块") }
        return parts.joined(separator: " · ")
    }

    private var draftSourceOrigin: ModuleSourceOrigin {
        guard let url = URL(string: draft.sourceURL), !draft.sourceURL.isEmpty else {
            return .invalid
        }
        if url.isFileURL { return .localSurgeFile }
        guard ["http", "https"].contains(url.scheme?.lowercased()) else { return .invalid }
        return .remote(draft.sourceFormat.resolvedFormat(for: url))
    }

    private var relationshipHint: String {
        switch (draft.storageLocation, draftSourceOrigin) {
        case (.local, .localSurgeFile):
            "纯本地模块：直接管理本地根目录中的 Surge .sgmodule。"
        case (.local, .remote):
            "本地模块，转换前来源是远程地址：会在本地根目录保留模块文件，并可从原始远程地址更新。"
        case (.gitHub, .remote):
            "GitHub 模块：转换结果按所选路径发布到 GitHub 模块目录。"
        case (.gitHub, .localSurgeFile):
            "GitHub 模块，转换前来源是本地 Surge 文件：适合把本地文件整理后发布到 GitHub。"
        case (_, .invalid):
            "先填写来源地址后，会显示清晰的存放位置与转换前来源关系。"
        }
    }

    private var previewPublishedRelativePath: String {
        draft.publishedRelativePath()
    }

    private var outputPathNotice: ModuleOutputPathNotice? {
        ModuleOutputPathInspector.notice(
            for: previewPublishedRelativePath,
            publishesStandalone: draft.publishesStandalone,
            modules: model.modules,
            editingModuleID: module?.id,
            combinedFileName: model.settings.combinedModuleFileName
        )
    }

    private var displayedIconPreviewURL: URL? {
        if let customIconPreviewURL { return customIconPreviewURL }
        guard !hasCustomIconInput else { return nil }
        return module?.iconURL.flatMap(URL.init(string:))
    }

    private var iconSourceTitle: String {
        if customIconInputIsInvalid { return "图标地址需检查" }
        if hasCustomIconInput { return "自定义图标" }
        if module?.iconURL != nil { return "来源图标" }
        return "默认图标"
    }

    private var editorPreviewCard: some View {
        ModuleEditorPreviewCard(
            title: editorPreviewTitle,
            subtitle: editorPreviewSubtitle,
            publishedRelativePath: previewPublishedRelativePath,
            iconURL: displayedIconPreviewURL,
            iconIsInvalid: customIconInputIsInvalid,
            iconSourceTitle: iconSourceTitle
        )
    }

    private var basicInfoSection: some View {
        ModuleEditorSection("基本信息") {
            ModuleEditorTextFieldRow(title: "显示名称", icon: "textformat", text: $draft.name, prompt: "例如：YouTube 去广告")
            ModuleEditorControlRow("模块存放", icon: draft.storageLocation.systemImage) {
                storageLocationPicker
            }
            ModuleEditorInfoRow("关系", icon: draftSourceOrigin.systemImage) {
                Text(relationshipHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ModuleEditorTextFieldRow(title: "模块标签", icon: "tag", text: $draft.category, prompt: "Surge category，例如：广告过滤")
            ModuleEditorControlRow("存放文件夹", icon: "folder") {
                folderPicker
            }
        }
    }

    private var iconSection: some View {
        ModuleEditorSection("图标") {
            ModuleEditorControlRow("图标 URL", icon: "photo") {
                HStack(spacing: 8) {
                    TextField("图标 URL", text: $draft.iconURL, prompt: Text("https://example.com/icon.png"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    if hasCustomIconInput {
                        Button {
                            draft.iconURL = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .help("清空自定义图标")
                    }
                    DraftModuleIconPreview(
                        url: displayedIconPreviewURL,
                        size: 30,
                        isInvalid: customIconInputIsInvalid
                    )
                }
            }
            ModuleEditorInfoRow(customIconInputIsInvalid ? "检查" : "兼容性", icon: customIconInputIsInvalid ? "exclamationmark.triangle" : "info.circle") {
                Text(iconURLHint)
                    .font(.caption)
                    .foregroundStyle(customIconInputIsInvalid ? .orange : .secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var publishingSection: some View {
        ModuleEditorSection("发布") {
            if model.settings.combinedModuleEnabled {
                ModuleEditorToggleRow(title: "包含在总模块中", icon: "square.stack.3d.up", isOn: $draft.isEnabled)
            }
            ModuleEditorToggleRow(title: "发布为独立模块", icon: "doc.badge.gearshape", isOn: $draft.publishesStandalone)
            ModuleEditorTextFieldRow(title: "输出文件名", icon: "doc", text: $draft.outputFileName, prompt: "留空时根据显示名称生成")
            ModuleEditorInfoRow("输出路径", icon: "folder") {
                ModuleEditorOutputPathRow(
                    relativePath: previewPublishedRelativePath,
                    notice: outputPathNotice
                )
            }
        }
    }

    private var sourceSection: some View {
        ModuleEditorSection("转换前来源") {
            ModuleEditorTextFieldRow(
                title: "来源地址",
                icon: "link",
                text: $draft.sourceURL,
                prompt: "https://example.com/module.plugin 或 file:///.../Demo.sgmodule"
            )
            ModuleEditorControlRow("来源格式", icon: "doc.text") {
                Picker("来源格式", selection: $draft.sourceFormat) {
                    ForEach(ModuleSourceFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220, alignment: .leading)
            }
        }
    }

    private var advancedEditorSection: some View {
        ModuleEditorSection("转换") {
            Button {
                withAnimation(.snappy) { isAdvancedExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .rotationEffect(.degrees(isAdvancedExpanded ? 90 : 0))
                    Text("高级")
                    Spacer()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isAdvancedExpanded {
                if isNativeSurgeModule {
                    Label(
                        "该地址是 Surge 模块，将直接参与合并，不经过 Script-Hub；高级转换选项不会应用。",
                        systemImage: "arrow.triangle.branch"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                } else {
                    ScriptHubAdvancedOptionsView(options: $draft.scriptHubOptions)
                }
            }
            Text("Loon 与 Quantumult X 来源可在这里使用 Script-Hub 原有的转换控制。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var folderPicker: some View {
        ModuleEditorFolderPicker(
            outputFolder: $draft.outputFolder,
            folders: model.moduleOutputFolderOptions(preserving: draft.outputFolder),
            onCreateFolder: {
                newFolderName = ""
                showsNewFolderDialog = true
            }
        )
    }

    private var storageLocationPicker: some View {
        ModuleEditorStorageLocationPicker(storageLocation: $draft.storageLocation)
    }

    private func autofillName(from urlString: String) {
        nameLookup?.cancel()
        guard draft.name.isEmpty else { return }
        guard ModuleEditorSourceNameLookup.remoteURL(from: urlString) != nil else { return }
        nameLookup = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, draft.name.isEmpty else { return }
            guard let resolved = await ModuleEditorSourceNameLookup.autofillName(from: urlString) else { return }
            guard !Task.isCancelled, draft.name.isEmpty else { return }
            draft.name = resolved
        }
    }

    private func save() {
        do {
            if let module {
                try model.updateModule(id: module.id, from: draft)
            } else {
                try model.addModule(from: draft)
            }
            dismiss()
        } catch {
            localError = error.localizedDescription
        }
    }

    private func createFolder() {
        do {
            let folder = try model.createModuleOutputFolder(named: newFolderName)
            draft.outputFolder = folder
        } catch {
            localError = error.localizedDescription
        }
    }
}
