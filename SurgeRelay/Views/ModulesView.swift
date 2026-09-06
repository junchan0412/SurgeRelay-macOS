import SwiftUI

struct ModulesView: View {
    @Environment(AppModel.self) private var model
    @State private var searchText = ""
    @State private var editorRoute: ModuleEditorRoute?
    @State private var deleteCandidate: ModuleDeleteCandidate?
    @State private var textEditModule: RelayModule?
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
    @AppStorage("ModulesView.sidebarFilter") private var sidebarFilter = ModuleFilter.all
    @AppStorage("ModulesView.sortOrder") private var sortOrder = ModuleSortOrder.nameAsc

    private var normalizedSearchText: String {
        ModuleSearchIndex.normalizedQuery(searchText)
    }

    private var contentIndexToken: String {
        normalizedSearchText.isEmpty ? "idle" : "\(normalizedSearchText)|\(model.moduleRevision)"
    }

    private var sidebarRefreshToken: SidebarRefreshKey {
        SidebarRefreshKey(revision: model.moduleRevision, query: normalizedSearchText, filter: sidebarFilter,
                          sort: sortOrder, combined: model.settings.combinedModuleEnabled,
                          contentKeys: contentIndexState.contentIndexCacheKeys)
    }

    private func rebuildContentIndex() async {
        if !normalizedSearchText.isEmpty {
            do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
        }
        let modules = model.modules
        let query = normalizedSearchText
        let state = contentIndexState
        let plan = await Task.detached(priority: .userInitiated) {
            ModuleSearchIndex.contentLoadPlan(modules: modules, query: query, state: state)
        }.value
        guard !Task.isCancelled else { return }
        guard !plan.isIdle else {
            if contentIndexState != .empty { contentIndexState = .empty }
            return
        }
        var nextState = plan.retainedState
        for module in plan.modulesToLoad {
            guard !Task.isCancelled else { return }
            let cacheKey = ModuleSearchIndex.contentCacheKey(for: module)
            if let content = try? await model.previewContent(for: module) {
                nextState.contentIndex[module.id] = await Task.detached(priority: .utility) { content.lowercased() }.value
                nextState.contentIndexCacheKeys[module.id] = cacheKey
            }
            await Task.yield()
        }
        guard !Task.isCancelled else { return }
        contentIndexState = nextState
    }

    private func rebuildSidebarPresentation() async {
        let modules = model.modules
        let query = normalizedSearchText
        let content = contentIndexState
        let metadata = metadataIndexState
        let filter = sidebarFilter
        let sort = sortOrder
        let combined = model.settings.combinedModuleEnabled
        let (nextMetadata, next) = await Task.detached(priority: .userInitiated) {
            let plan = ModuleSearchIndex.filterPlan(modules: modules, query: query, contentState: content, metadataState: metadata)
            let filtered = filter == .all ? plan.matches : plan.matches.filter { filter.matches($0, combinedModuleEnabled: combined) }
            let sorted = sort.sorted(filtered)
            let presentation = SidebarPresentation(
                sections: ModuleSidebarSectionPlanner.sections(for: sorted),
                filteredModulesAreEmpty: sorted.isEmpty, allModulesAreEmpty: modules.isEmpty,
                combinedModuleEnabled: combined,
                filterCounts: ModuleFilter.counts(for: plan.matches, combinedModuleEnabled: combined),
                resultCount: sorted.count
            )
            return (plan.metadataState, presentation)
        }.value
        guard !Task.isCancelled else { return }
        metadataIndexState = nextMetadata
        if next != sidebarPresentation { sidebarPresentation = next }
    }

    private func showModules(_ filter: ModuleFilter) {
        sidebarFilter = filter
        searchText = ""
        if let first = sortOrder.sorted(model.modules).first(where: { filter.matches($0, combinedModuleEnabled: model.settings.combinedModuleEnabled) }) {
            model.selectedModuleID = first.id
        }
        columnVisibility = .all
    }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ModuleSidebarView(
                sections: sidebarPresentation.sections,
                filteredModulesAreEmpty: sidebarPresentation.filteredModulesAreEmpty,
                allModulesAreEmpty: sidebarPresentation.allModulesAreEmpty,
                combinedModuleEnabled: sidebarPresentation.combinedModuleEnabled,
                filterCounts: sidebarPresentation.filterCounts,
                resultCount: sidebarPresentation.resultCount,
                hasSearchQuery: !normalizedSearchText.isEmpty,
                searchText: $searchText,
                sidebarFilter: $sidebarFilter,
                sortOrder: $sortOrder,
                isBatchSelecting: $isBatchSelecting,
                batchSelectedModuleIDs: $batchSelectedModuleIDs,
                deleteCandidate: $deleteCandidate,
                editModule: presentEditor,
                textEditModule: { textEditModule = $0 },
                addModule: { editorRoute = ModuleEditorRoute(module: nil) }
            )
            .navigationSplitViewColumnWidth(min: 260, ideal: 292, max: 360)
            .navigationTitle("Surge Relay")
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
            ModuleDetailPaneView(
                editModule: presentEditor,
                addModule: { editorRoute = ModuleEditorRoute(module: nil) },
                scanLocalModules: scanLocalModulesForPreview,
                filterModules: showModules
            )
        }
        .task(id: contentIndexToken) { await rebuildContentIndex() }
        .task(id: sidebarRefreshToken) { await rebuildSidebarPresentation() }
        .sheet(item: $editorRoute) { route in
            ModuleEditorView(
                module: route.module,
                defaultStorageLocation: .preferredDefault(
                    publishToLocal: model.settings.publishToLocal
                )
            )
                .environment(model)
        }
        .sheet(item: $textEditModule) { module in
            ModuleTextEditorView(module: module)
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
                        .accessibilityIdentifier("settings.done")
                }
            }
            .frame(width: 820, height: 620)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.root")
        }
        .sheet(isPresented: $model.presentsUpdateChecker) {
            CheckForUpdatesSheet()
                .frame(width: 560)
        }
        .confirmationDialog(
            "删除“\(deleteCandidate?.module.name ?? "")”？",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            )
        ) {
            Button(deleteConfirmTitle, role: .destructive) {
                guard let candidate = deleteCandidate else { return }
                deleteCandidate = nil
                Task { await model.deleteModule(id: candidate.module.id, mode: candidate.mode) }
            }
            Button("取消", role: .cancel) { deleteCandidate = nil }
        } message: {
            Text(deleteConfirmMessage)
        }
    }

    private func presentEditor(_ module: RelayModule) {
        editorRoute = ModuleEditorRoute(module: module)
    }

    private var deleteConfirmTitle: String {
        guard let mode = deleteCandidate?.mode else { return "删除" }
        switch mode {
        case .removeFromList: return "移除"
        case .clearOutput: return "删除并清理输出"
        case .deleteAll: return "彻底删除（含源文件）"
        }
    }

    private var deleteConfirmMessage: String {
        guard let mode = deleteCandidate?.mode else { return "" }
        switch mode {
        case .removeFromList:
            return "仅从 Surge Relay 管理列表移除，磁盘上的输出文件保留。"
        case .clearOutput:
            return "从管理列表移除，并删除受 Surge Relay 管理的输出文件；自写模块的用户源文件安全保留。"
        case .deleteAll:
            return "从管理列表移除，并连同磁盘上的输出 / 源文件一并删除，此操作不可撤销。"
        }
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

private struct SidebarPresentation: Equatable, Sendable {
    var sections: [ModuleSidebarSection]
    var filteredModulesAreEmpty: Bool
    var allModulesAreEmpty: Bool
    var combinedModuleEnabled: Bool
    var filterCounts: [ModuleFilter: Int]
    var resultCount: Int

    static let empty = SidebarPresentation(
        sections: [],
        filteredModulesAreEmpty: true,
        allModulesAreEmpty: true,
        combinedModuleEnabled: false,
        filterCounts: [:],
        resultCount: 0
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

private struct SidebarRefreshKey: Equatable {
    var revision: UInt64
    var query: String
    var filter: ModuleFilter
    var sort: ModuleSortOrder
    var combined: Bool
    var contentKeys: [UUID: String]
}
