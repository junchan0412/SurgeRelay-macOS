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

            Form {
                Section("基本信息") {
                    TextField("显示名称", text: $draft.name, prompt: Text("例如：YouTube 去广告"))
                    TextField("模块标签（category）", text: $draft.category, prompt: Text("例如：广告过滤"))
                    LabeledContent("存放文件夹") {
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
                    if model.settings.combinedModuleEnabled {
                        Toggle("包含在总模块中", isOn: $draft.isEnabled)
                    }
                    Toggle("发布为独立模块", isOn: $draft.publishesStandalone)
                }
                Section("来源") {
                    TextField("原始地址", text: $draft.sourceURL, prompt: Text("https://example.com/module.plugin 或 file:///.../Demo.sgmodule"))
                        .lineLimit(1)
                    Picker("来源格式", selection: $draft.sourceFormat) {
                        ForEach(ModuleSourceFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                }
                Section {
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
                                "该地址是 Surge 模块，将直接参与合并，不经过 Script‑Hub；高级转换选项不会应用。",
                                systemImage: "arrow.triangle.branch"
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 10)
                        } else {
                            ScriptHubAdvancedOptionsView(options: $draft.scriptHubOptions)
                        }
                    }
                } footer: {
                    Text("Loon 与 Quantumult X 来源可在这里使用 Script‑Hub 原有的转换控制。")
                }
            }
            .formStyle(.grouped)
            .task {
                await model.refreshModuleOutputFolders()
            }
            .onChange(of: draft.sourceURL) { _, newValue in
                autofillName(from: newValue)
            }

            Divider()
            HStack {
                Button("取消", role: .cancel) { dismiss() }
                Spacer()
                Button(module == nil ? "添加" : "保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
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
