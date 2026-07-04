import AppKit
import SwiftUI

struct ModulesView: View {
    @Environment(AppModel.self) private var model
    @State private var searchText = ""
    @State private var editorRoute: ModuleEditorRoute?
    @State private var deleteCandidate: RelayModule?
    @State private var detailTab: DetailTab = .info
    @State private var contentIndex: [UUID: String] = [:]
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isScanningLocalModules = false
    @State private var showsLocalImportPreview = false
    @State private var localImportCandidates: [LocalModuleScanCandidate] = []
    @State private var localImportSkippedFiles: [LocalModuleScanSkippedFile] = []
    @State private var selectedLocalImportCandidateIDs = Set<String>()
    @State private var isBatchSelecting = false
    @State private var batchSelectedModuleIDs = Set<UUID>()

    private enum DetailTab: Hashable { case info, preview }

    private enum SelectionKind {
        case combined
        case module(RelayModule)
    }

    private var selectionKind: SelectionKind? {
        if model.settings.combinedModuleEnabled,
           model.selectedModuleID == AppModel.combinedModuleSelectionID {
            return .combined
        }
        if let id = model.selectedModuleID,
           let module = model.modules.first(where: { $0.id == id }) {
            return .module(module)
        }
        return nil
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var filteredModules: [RelayModule] {
        let query = normalizedSearchText
        guard !query.isEmpty else { return model.modules }
        return model.modules.filter { searchableText(for: $0).contains(query) }
    }

    private var sidebarSections: [ModuleSidebarSection] {
        let values = filteredModules
        return [
            ModuleSidebarSection(
                id: "attention",
                title: "需要处理",
                systemImage: "exclamationmark.triangle",
                modules: values.filter { $0.state == .failed || $0.hasOverrideConflict }
            ),
            ModuleSidebarSection(
                id: "local",
                title: "本地模块",
                systemImage: "folder",
                modules: values.filter { module in
                    module.state != .failed && !module.hasOverrideConflict && module.storageLocation == .local && module.sourceOrigin != .invalid
                }
            ),
            ModuleSidebarSection(
                id: "github",
                title: "GitHub 模块",
                systemImage: "cloud",
                modules: values.filter { module in
                    module.state != .failed && !module.hasOverrideConflict && module.storageLocation == .gitHub && module.sourceOrigin != .invalid
                }
            ),
            ModuleSidebarSection(
                id: "uncategorized",
                title: "未分类",
                systemImage: "link.badge.plus",
                modules: values.filter { module in
                    module.state != .failed && !module.hasOverrideConflict && module.sourceOrigin == .invalid
                }
            )
        ].filter { !$0.modules.isEmpty }
    }

    private func searchableText(for module: RelayModule) -> String {
        ModuleSearchIndex.text(for: module, cachedContent: contentIndex[module.id])
    }

    private var contentIndexToken: String {
        guard !normalizedSearchText.isEmpty else { return "idle" }
        return "active|" + model.modules
            .map { "\($0.id.uuidString):\($0.contentHash ?? "")" }
            .joined(separator: "|")
    }

    private func rebuildContentIndex() async {
        guard !normalizedSearchText.isEmpty else {
            if !contentIndex.isEmpty { contentIndex.removeAll() }
            return
        }
        var index: [UUID: String] = [:]
        for module in model.modules {
            guard !Task.isCancelled else { return }
            if let content = try? await model.previewContent(for: module) {
                index[module.id] = content.lowercased()
            }
            await Task.yield()
        }
        guard !Task.isCancelled else { return }
        contentIndex = index
    }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ModuleSidebarView(
                sections: sidebarSections,
                filteredModulesAreEmpty: filteredModules.isEmpty,
                allModulesAreEmpty: model.modules.isEmpty,
                isBatchSelecting: $isBatchSelecting,
                batchSelectedModuleIDs: $batchSelectedModuleIDs,
                deleteCandidate: $deleteCandidate,
                editModule: presentEditor
            )
            .navigationSplitViewColumnWidth(min: 280, ideal: 300, max: 380)
            .navigationTitle("模块")
            .toolbar {
                if columnVisibility != .detailOnly {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            editorRoute = ModuleEditorRoute(module: nil)
                        } label: {
                            Label("添加模块", systemImage: "plus")
                        }
                        Button {
                            model.startUpdateAll()
                        } label: {
                            Label("更新全部", systemImage: "arrow.clockwise")
                        }
                        .disabled(!model.updateAdmission.isAccepted)
                        .help(model.updateAdmission.isAccepted ? "更新全部模块" : model.updateAdmission.message)
                        Button {
                            Task { await model.publishAll() }
                        } label: {
                            Label("发布全部", systemImage: "square.and.arrow.up")
                        }
                        .disabled(model.isWorking || !model.settings.publishToGitHub || !model.settings.github.isConfigured)
                        .help(model.settings.publishToGitHub ? "发布当前所有输出到 GitHub" : "未开启 GitHub 发布")
                        Button {
                            isBatchSelecting.toggle()
                            if !isBatchSelecting { batchSelectedModuleIDs.removeAll() }
                        } label: {
                            Label(isBatchSelecting ? "结束选择" : "多选", systemImage: isBatchSelecting ? "checkmark.circle" : "checklist")
                        }
                        .disabled(model.isWorking)
                        if isBatchSelecting {
                            Button {
                                let ids = batchSelectedModuleIDs
                                Task {
                                    if await model.publishModules(moduleIDs: ids) {
                                        batchSelectedModuleIDs.removeAll()
                                        isBatchSelecting = false
                                    }
                                }
                            } label: {
                                Label("发布所选", systemImage: "square.and.arrow.up.on.square")
                            }
                            .disabled(
                                model.isWorking ||
                                batchSelectedModuleIDs.isEmpty ||
                                !model.settings.publishToGitHub ||
                                !model.settings.github.isConfigured
                            )
                            .help(batchSelectedModuleIDs.isEmpty ? "请选择要发布的模块" : "只发布勾选模块，不删除其他已发布文件")
                        }
                        Button {
                            scanLocalModulesForPreview()
                        } label: {
                            Label("扫描本地模块", systemImage: "folder.badge.plus")
                        }
                        .disabled(model.isWorking || isScanningLocalModules)
                        .help("扫描本地模块根目录下已有的 .sgmodule，并纳入 Surge Relay 管理")
                    }
                }
            }
        } detail: {
            Group {
                if let kind = selectionKind {
                    // Keep both panes mounted and just toggle opacity, so switching
                    // tabs never destroys/recreates (and re-loads) the code preview
                    // view — that recreation is what caused the white flash.
                    ZStack {
                        switch kind {
                        case .combined:
                            CombinedModuleDetailView()
                                .opacity(detailTab == .info ? 1 : 0)
                                .allowsHitTesting(detailTab == .info)
                            CombinedPreviewPane()
                                .opacity(detailTab == .preview ? 1 : 0)
                                .allowsHitTesting(detailTab == .preview)
                        case let .module(module):
                            ModuleDetailView(module: module, onEdit: { presentEditor(module) })
                                .opacity(detailTab == .info ? 1 : 0)
                                .allowsHitTesting(detailTab == .info)
                            ModulePreviewPane(module: module)
                                .opacity(detailTab == .preview ? 1 : 0)
                                .allowsHitTesting(detailTab == .preview)
                        }
                    }
                } else {
                    ContentUnavailableView("选择一个模块", systemImage: "sidebar.right")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .searchable(text: $searchText, prompt: "搜索")
            .toolbar {
                ToolbarSpacer(.flexible)
                if selectionKind != nil {
                    ToolbarItem {
                        Picker("视图", selection: $detailTab) {
                            Image(systemName: "info.circle")
                                .accessibilityLabel("详情")
                                .tag(DetailTab.info)
                            Image(systemName: "curlybraces")
                                .accessibilityLabel("预览")
                                .tag(DetailTab.preview)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
                ToolbarItem {
                    Button {
                        model.presentsSettings = true
                    } label: {
                        Label("设置", systemImage: "gearshape")
                    }
                    .help("设置")
                }
            }
        }
        .onChange(of: model.selectedModuleID) { _, _ in detailTab = .info }
        .task(id: contentIndexToken) { await rebuildContentIndex() }
        .sheet(item: $editorRoute) { route in
            ModuleEditorView(module: route.module)
                .environment(model)
        }
        .sheet(isPresented: $showsLocalImportPreview) {
            LocalModuleImportPreviewView(
                candidates: localImportCandidates,
                skippedFiles: localImportSkippedFiles,
                selectedCandidateIDs: $selectedLocalImportCandidateIDs
            )
            .environment(model)
        }
        .sheet(isPresented: $model.presentsSettings) {
            VStack(spacing: 0) {
                SettingsView()
                    .environment(model)

                SheetActionFooter {
                    Spacer()
                    Button("完成") { model.presentsSettings = false }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .frame(width: 620, height: 560)
        }
        .sheet(isPresented: $model.presentsUpdateChecker) {
            CheckForUpdatesSheet()
                .frame(width: 560)
        }
        .confirmationDialog(
            "删除“\(deleteCandidate?.name ?? "")”？",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            )
        ) {
            Button(model.settings.combinedModuleEnabled ? "删除来源并重新合并" : "删除来源并刷新输出", role: .destructive) {
                guard let id = deleteCandidate?.id else { return }
                deleteCandidate = nil
                Task { await model.deleteModule(id: id) }
            }
            Button("取消", role: .cancel) { deleteCandidate = nil }
        } message: {
            Text(model.settings.combinedModuleEnabled ? "该来源会从总模块中移除；下次发布如需删除旧文件，会先显示预览并要求确认。" : "该来源会从 Surge Relay 管理列表中移除；下次发布如需删除旧文件，会先显示预览并要求确认。")
        }
    }

    private func presentEditor(_ module: RelayModule) {
        editorRoute = ModuleEditorRoute(module: module)
    }

    @MainActor
    private func scanLocalModulesForPreview() {
        guard !model.isWorking, !isScanningLocalModules else { return }
        isScanningLocalModules = true
        Task { @MainActor in
            defer { isScanningLocalModules = false }
            do {
                let report = try await model.scanExistingLocalModules()
                guard !report.candidates.isEmpty || !report.skippedFiles.isEmpty else { return }
                localImportCandidates = report.candidates
                localImportSkippedFiles = report.skippedFiles
                selectedLocalImportCandidateIDs = Set(report.candidates.map(\.id))
                showsLocalImportPreview = true
            } catch {
                model.presentedError = "扫描本地模块失败：\(error.localizedDescription)"
                model.statusMessage = "本地模块扫描失败"
            }
        }
    }

}

private struct ModuleEditorRoute: Identifiable {
    let id: UUID
    let module: RelayModule?

    init(module: RelayModule?) {
        self.module = module
        id = module?.id ?? UUID()
    }
}
