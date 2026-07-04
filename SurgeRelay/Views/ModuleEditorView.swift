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
            Text(model.settings.storageMode == .local
                ? "将在本地模块根目录下创建文件夹。"
                : "GitHub 不支持空文件夹；该路径会先保存为选项，发布模块时自动创建。")
        }
    }

    private var editorPreviewTitle: String {
        let value = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "未命名模块" : value
    }

    private var editorPreviewSubtitle: String {
        var parts = [draft.sourceFormat.title]
        let category = draft.category.trimmingCharacters(in: .whitespacesAndNewlines)
        if !category.isEmpty { parts.append(category) }
        if !draft.publishesStandalone { parts.append("不发布独立模块") }
        return parts.joined(separator: " · ")
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
        HStack(alignment: .center, spacing: 14) {
            DraftModuleIconPreview(
                url: displayedIconPreviewURL,
                size: 54,
                isInvalid: customIconInputIsInvalid
            )
            VStack(alignment: .leading, spacing: 7) {
                Text(editorPreviewTitle)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text(editorPreviewSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(previewPublishedRelativePath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Label(iconSourceTitle, systemImage: customIconInputIsInvalid ? "exclamationmark.triangle" : "photo")
                    .font(.caption)
                    .foregroundStyle(customIconInputIsInvalid ? .orange : .secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.22), lineWidth: 0.5)
        }
    }

    private var basicInfoSection: some View {
        editorSection("基本信息") {
            editorTextFieldRow("显示名称", icon: "textformat", text: $draft.name, prompt: "例如：YouTube 去广告")
            editorTextFieldRow("模块标签", icon: "tag", text: $draft.category, prompt: "Surge category，例如：广告过滤")
            EditorControlRow("存放文件夹", icon: "folder") {
                folderPicker
            }
        }
    }

    private var iconSection: some View {
        editorSection("图标") {
            EditorControlRow("图标 URL", icon: "photo") {
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
            EditorInfoRow(customIconInputIsInvalid ? "检查" : "兼容性", icon: customIconInputIsInvalid ? "exclamationmark.triangle" : "info.circle") {
                Text(iconURLHint)
                    .font(.caption)
                    .foregroundStyle(customIconInputIsInvalid ? .orange : .secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var publishingSection: some View {
        editorSection("发布") {
            if model.settings.combinedModuleEnabled {
                editorToggleRow("包含在总模块中", icon: "square.stack.3d.up", isOn: $draft.isEnabled)
            }
            editorToggleRow("发布为独立模块", icon: "doc.badge.gearshape", isOn: $draft.publishesStandalone)
            editorTextFieldRow("输出文件名", icon: "doc", text: $draft.outputFileName, prompt: "留空时根据显示名称生成")
            EditorInfoRow("输出路径", icon: "folder") {
                VStack(alignment: .leading, spacing: 6) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 8) {
                            outputPathText(fixedHorizontal: true)
                            TextCopyButton(text: previewPublishedRelativePath)
                                .layoutPriority(1)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            outputPathText(fixedHorizontal: false)
                            TextCopyButton(text: previewPublishedRelativePath)
                        }
                    }
                    if let outputPathNotice {
                        Label(outputPathNotice.message, systemImage: outputPathNotice.isWarning ? "exclamationmark.triangle" : "info.circle")
                            .font(.caption)
                            .foregroundStyle(outputPathNotice.isWarning ? .orange : .secondary)
                    }
                }
            }
        }
    }

    private func outputPathText(fixedHorizontal: Bool) -> some View {
        Text(previewPublishedRelativePath)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: fixedHorizontal, vertical: true)
            .frame(maxWidth: fixedHorizontal ? nil : .infinity, alignment: .leading)
    }

    private var sourceSection: some View {
        editorSection("来源") {
            editorTextFieldRow(
                "原始地址",
                icon: "link",
                text: $draft.sourceURL,
                prompt: "https://example.com/module.plugin 或 file:///.../Demo.sgmodule"
            )
            EditorControlRow("来源格式", icon: "doc.text") {
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
        editorSection("转换") {
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
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { ModuleOutputFolder.normalized(draft.outputFolder) },
                set: { draft.outputFolder = $0 }
            )) {
                ForEach(model.moduleOutputFolderOptions(preserving: draft.outputFolder), id: \.self) { folder in
                    Text(ModuleOutputFolder.displayTitle(for: folder)).tag(folder)
                }
            }
            .labelsHidden()

            Button {
                newFolderName = ""
                showsNewFolderDialog = true
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .help("新建存放文件夹")
        }
    }

    private func editorTextFieldRow(
        _ title: String,
        icon: String,
        text: Binding<String>,
        prompt: String
    ) -> some View {
        EditorControlRow(title, icon: icon) {
            TextField(title, text: text, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
        }
    }

    private func editorToggleRow(_ title: String, icon: String, isOn: Binding<Bool>) -> some View {
        EditorControlRow(title, icon: icon) {
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private func editorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.headline)
                .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 11) {
                content()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.18), lineWidth: 0.5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Auto-fills the name from the module's own `#!name=` metadata (Surge / Loon)
    /// by fetching the source; falls back to a name derived from the URL when the
    /// module has no embedded name (e.g. most Quantumult X rewrites). Debounced and
    /// only runs while the name field is still empty.
    private func autofillName(from urlString: String) {
        nameLookup?.cancel()
        guard draft.name.isEmpty else { return }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              ["http", "https"].contains(url.scheme?.lowercased()) else { return }
        let fallback = FilenameSanitizer.suggestedName(from: trimmed)
            .replacingOccurrences(of: "-", with: " ")
        nameLookup = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, draft.name.isEmpty else { return }
            var request = URLRequest(url: url)
            request.setValue("Surge Relay", forHTTPHeaderField: "User-Agent")
            var resolved = fallback
            if let (data, _) = try? await URLSession.shared.data(for: request),
               let content = String(data: data, encoding: .utf8),
               let name = ModuleMetadataParser.displayName(in: content) {
                resolved = name
            }
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

private struct EditorInfoRow<Content: View>: View {
    let title: String
    let icon: String
    private let content: () -> Content

    init(_ title: String, icon: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)
            Text(title)
                .font(.callout.weight(.medium))
                .frame(width: 108, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.14))
                .frame(height: 0.5)
                .padding(.leading, 30)
        }
    }
}

private struct EditorControlRow<Content: View>: View {
    let title: String
    let icon: String
    private let content: () -> Content

    init(_ title: String, icon: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content
    }

    var body: some View {
        EditorInfoRow(title, icon: icon) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DraftModuleIconPreview: View {
    let url: URL?
    let size: CGFloat
    var isInvalid = false

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        previewContainer(
                            placeholder.overlay { ProgressView().controlSize(.mini) },
                            isWarning: isInvalid
                        )
                    case let .success(image):
                        previewContainer(image.resizable().scaledToFill(), isWarning: isInvalid)
                    case .failure:
                        previewContainer(warningPlaceholder, isWarning: true)
                    @unknown default:
                        previewContainer(placeholder, isWarning: isInvalid)
                    }
                }
            } else {
                previewContainer(placeholder, isWarning: isInvalid)
            }
        }
        .accessibilityHidden(true)
    }

    private func previewContainer<Content: View>(_ content: Content, isWarning: Bool) -> some View {
        content
        .frame(width: size, height: size)
        .background(.quaternary.opacity(0.35), in: iconShape)
        .clipShape(iconShape)
        .overlay {
            iconShape
                .strokeBorder(
                    isWarning ? Color.orange.opacity(0.72) : Color(nsColor: .separatorColor).opacity(0.45),
                    lineWidth: isWarning ? 1 : 0.5
                )
        }
    }

    private var placeholder: some View {
        Image(systemName: isInvalid ? "exclamationmark.triangle" : "photo")
            .font(.system(size: size * 0.45))
            .foregroundStyle(isInvalid ? .orange : .secondary)
            .frame(width: size, height: size)
    }

    private var warningPlaceholder: some View {
        Image(systemName: "exclamationmark.triangle")
            .font(.system(size: size * 0.45))
            .foregroundStyle(.orange)
            .frame(width: size, height: size)
    }

    private var iconShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * ModuleIconView.cornerRadiusRatio, style: .continuous)
    }
}
