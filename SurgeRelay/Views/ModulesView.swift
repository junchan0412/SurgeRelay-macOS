import SwiftUI

struct ModulesView: View {
    @Environment(AppModel.self) private var model
    @State private var searchText = ""
    @State private var editorRoute: ModuleEditorRoute?
    @State private var deleteCandidate: RelayModule?
    @State private var contentIndexState = ModuleSearchContentIndexState()
    @State private var metadataIndexState = ModuleSearchMetadataIndexState()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isScanningLocalModules = false
    @State private var showsLocalImportPreview = false
    @State private var localImportCandidates: [LocalModuleScanCandidate] = []
    @State private var localImportSkippedFiles: [LocalModuleScanSkippedFile] = []
    @State private var selectedLocalImportCandidateIDs = Set<String>()
    @State private var isBatchSelecting = false
    @State private var batchSelectedModuleIDs = Set<UUID>()
    @State private var sidebarPresentation = SidebarPresentation.empty

    private var normalizedSearchText: String {
        ModuleSearchIndex.normalizedQuery(searchText)
    }

    private var contentIndexToken: String {
        ModuleSearchIndex.contentIndexToken(
            for: model.modules,
            query: normalizedSearchText
        )
    }

    private var sidebarRefreshToken: String {
        // Include fields that affect grouping/filtering, but not high-frequency
        // progress counters that should not rebuild the entire section tree.
        let modulesSignature = model.modules.map { module in
            [
                module.id.uuidString,
                module.name,
                module.state.rawValue,
                module.isEnabled ? "1" : "0",
                module.publishesStandalone ? "1" : "0",
                module.storageLocation.rawValue,
                module.category,
                module.outputFolder,
                module.hasOverrideConflict ? "1" : "0",
                module.contentHash ?? "",
                module.lastError.map { String($0.hashValue) } ?? "",
                module.initialSource.title,
            ].joined(separator: ":")
        }.joined(separator: "|")
        return [
            normalizedSearchText,
            model.settings.combinedModuleEnabled ? "1" : "0",
            contentIndexState.contentIndexCacheKeys
                .map { "\($0.key.uuidString)=\($0.value)" }
                .sorted()
                .joined(separator: ","),
            modulesSignature,
        ].joined(separator: "\u{1e}")
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

    private func rebuildSidebarPresentation() {
        let filterPlan = ModuleSearchIndex.filterPlan(
            modules: model.modules,
            query: normalizedSearchText,
            contentState: contentIndexState,
            metadataState: metadataIndexState
        )
        metadataIndexState = filterPlan.metadataState
        let sections = ModuleSidebarSectionPlanner.sections(for: filterPlan.matches)
        let next = SidebarPresentation(
            sections: sections,
            filteredModulesAreEmpty: filterPlan.matches.isEmpty,
            allModulesAreEmpty: model.modules.isEmpty,
            combinedModuleEnabled: model.settings.combinedModuleEnabled
        )
        guard next != sidebarPresentation else { return }
        sidebarPresentation = next
    }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ModuleSidebarView(
                sections: sidebarPresentation.sections,
                filteredModulesAreEmpty: sidebarPresentation.filteredModulesAreEmpty,
                allModulesAreEmpty: sidebarPresentation.allModulesAreEmpty,
                combinedModuleEnabled: sidebarPresentation.combinedModuleEnabled,
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
        .onChange(of: sidebarRefreshToken, initial: true) { _, _ in
            rebuildSidebarPresentation()
        }
        .sheet(item: $editorRoute) { route in
            ModuleEditorView(
                module: route.module,
                defaultStorageLocation: .preferredDefault(
                    publishToLocal: model.settings.publishToLocal
                )
            )
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

private struct SidebarPresentation: Equatable {
    var sections: [ModuleSidebarSection]
    var filteredModulesAreEmpty: Bool
    var allModulesAreEmpty: Bool
    var combinedModuleEnabled: Bool

    static let empty = SidebarPresentation(
        sections: [],
        filteredModulesAreEmpty: true,
        allModulesAreEmpty: true,
        combinedModuleEnabled: false
    )
}

private struct ModuleEditorRoute: Identifiable {
    let id: UUID
    let module: RelayModule?

    init(module: RelayModule?) {
        self.module = module
        id = module?.id ?? UUID()
    }
}
