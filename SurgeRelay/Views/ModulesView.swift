import SwiftUI

struct ModulesView: View {
    @Environment(AppModel.self) private var model
    @State private var searchText = ""
    @State private var editorRoute: ModuleEditorRoute?
    @State private var deleteCandidate: RelayModule?
    @State private var contentIndexState = ModuleSearchContentIndexState()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isScanningLocalModules = false
    @State private var showsLocalImportPreview = false
    @State private var localImportCandidates: [LocalModuleScanCandidate] = []
    @State private var localImportSkippedFiles: [LocalModuleScanSkippedFile] = []
    @State private var selectedLocalImportCandidateIDs = Set<String>()
    @State private var isBatchSelecting = false
    @State private var batchSelectedModuleIDs = Set<UUID>()

    private var normalizedSearchText: String {
        ModuleSearchIndex.normalizedQuery(searchText)
    }

    private var filteredModules: [RelayModule] {
        let query = normalizedSearchText
        guard !query.isEmpty else { return model.modules }
        return model.modules.filter { searchableText(for: $0).contains(query) }
    }

    private var sidebarSections: [ModuleSidebarSection] {
        ModuleSidebarSectionPlanner.sections(for: filteredModules)
    }

    private func searchableText(for module: RelayModule) -> String {
        ModuleSearchIndex.text(
            for: module,
            cachedContent: ModuleSearchIndex.cachedContent(
                for: module,
                contentIndex: contentIndexState.contentIndex,
                contentIndexCacheKeys: contentIndexState.contentIndexCacheKeys
            )
        )
    }

    private var contentIndexToken: String {
        ModuleSearchIndex.contentIndexToken(
            for: model.modules,
            query: normalizedSearchText
        )
    }

    private func rebuildContentIndex() async {
        let plan = ModuleSearchIndex.contentLoadPlan(
            modules: model.modules,
            query: normalizedSearchText,
            state: contentIndexState
        )
        guard !plan.isIdle else {
            if contentIndexState != .empty { contentIndexState = .empty }
            return
        }
        var nextState = plan.retainedState
        for module in plan.modulesToLoad {
            guard !Task.isCancelled else { return }
            let cacheKey = ModuleSearchIndex.contentCacheKey(for: module)
            if let content = try? await model.previewContent(for: module) {
                nextState.contentIndex[module.id] = content.lowercased()
                nextState.contentIndexCacheKeys[module.id] = cacheKey
            }
            await Task.yield()
        }
        guard !Task.isCancelled else { return }
        contentIndexState = nextState
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
                    ModuleSidebarToolbarContent(
                        isBatchSelecting: $isBatchSelecting,
                        batchSelectedModuleIDs: $batchSelectedModuleIDs,
                        isScanningLocalModules: isScanningLocalModules,
                        addModule: { editorRoute = ModuleEditorRoute(module: nil) },
                        scanLocalModules: scanLocalModulesForPreview
                    )
                }
            }
        } detail: {
            ModuleDetailPaneView(searchText: $searchText, editModule: presentEditor)
        }
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
                model.statusMessage = LocalModuleImportPlanner.scanFailedStatus
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
