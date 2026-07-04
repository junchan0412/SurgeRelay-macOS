import AppKit
import SwiftUI

enum ModuleSearchIndex {
    static func text(for module: RelayModule, cachedContent: String? = nil) -> String {
        var parts = [
            module.name,
            module.sourceURL,
            module.outputFileName,
            module.publishedRelativePath,
            module.sourceFormatDisplayTitle,
            module.category,
            module.outputFolder,
            ModuleOutputFolder.displayTitle(for: module.outputFolder),
            module.storageLocation.title,
            module.storageLocation.detail,
            module.sourceOrigin.title,
            module.relationshipSummary,
            module.publishesStandalone ? "独立模块" : "不发布独立模块",
            module.state.title,
        ]
        if let iconURL = module.iconURL { parts.append(iconURL) }
        if let customIconURL = module.customIconURL { parts.append(customIconURL) }
        if let lastError = module.lastError { parts.append(lastError) }
        if let subscription = module.scriptHubSubscription {
            parts.append(subscription.subscriptionURL)
            parts.append(subscription.originalURL)
            parts.append(subscription.displaySummary)
            if let outputName = subscription.outputName { parts.append(outputName) }
            if let sourceType = subscription.sourceType { parts.append(sourceType) }
            if let target = subscription.target { parts.append(target) }
            if let category = subscription.category { parts.append(category) }
        }
        parts.append(contentsOf: module.argumentOverrides.flatMap { [$0.key, $0.value] })
        if let data = try? JSONEncoder().encode(module.scriptHubOptions),
           let text = String(data: data, encoding: .utf8) {
            parts.append(text)
        }
        if let cachedContent {
            parts.append(cachedContent)
        }
        return parts.joined(separator: "\n").lowercased()
    }
}
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

    private struct SidebarModuleSection: Identifiable {
        let id: String
        let title: String
        let systemImage: String
        let modules: [RelayModule]
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

    private var sidebarSections: [SidebarModuleSection] {
        let values = filteredModules
        return [
            SidebarModuleSection(
                id: "attention",
                title: "需要处理",
                systemImage: "exclamationmark.triangle",
                modules: values.filter { $0.state == .failed || $0.hasOverrideConflict }
            ),
            SidebarModuleSection(
                id: "local",
                title: "本地模块",
                systemImage: "folder",
                modules: values.filter { module in
                    module.state != .failed && !module.hasOverrideConflict && module.storageLocation == .local && module.sourceOrigin != .invalid
                }
            ),
            SidebarModuleSection(
                id: "github",
                title: "GitHub 模块",
                systemImage: "cloud",
                modules: values.filter { module in
                    module.state != .failed && !module.hasOverrideConflict && module.storageLocation == .gitHub && module.sourceOrigin != .invalid
                }
            ),
            SidebarModuleSection(
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

    /// Floating status / latest-update card pinned to the bottom of the sidebar.
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.presentedError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button {
                        model.presentedError = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                Divider()
            }

            if model.workActivity.isActive {
                if model.workActivity.kind == .updatingModules,
                   let name = synchronizingModuleName,
                   model.synchronizationTotalCount > 0 {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(name)
                                .lineLimit(1)
                                .contentTransition(.identity)
                            Spacer(minLength: 4)
                            Text("\(synchronizationPercentage)%")
                                .monospacedDigit()
                                .contentTransition(.numericText(value: Double(synchronizationPercentage)))
                                .animation(.smooth(duration: 0.25), value: synchronizationPercentage)
                        }
                        .font(.caption)
                        ProgressView(value: synchronizationProgress)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                            .animation(.smooth(duration: 0.25), value: synchronizationProgress)
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(workActivityStatusText)
                            .font(.caption)
                            .lineLimit(2)
                    }
                }
                if model.workActivity.canCancel {
                    Button {
                        model.cancelCurrentWork()
                    } label: {
                        Label(model.workCancellationRequested ? "正在取消…" : "取消当前任务", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(!model.canCancelCurrentWork)
                }
                Divider()
            }

            if let automaticPublishText {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "paperplane.circle.fill")
                        .foregroundStyle(.blue)
                    Text(automaticPublishText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("最新更新时间")
                    .font(.caption.weight(.medium))
                Text(latestUpdateText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: statusCardShape)
        .overlay {
            statusCardShape
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.24), lineWidth: 0.5)
        }
        .glassEffect(.regular, in: statusCardShape)
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .animation(.snappy, value: model.workActivity)
        .animation(.snappy, value: model.presentedError)
        .animation(.snappy, value: model.automaticPublishRunsAt)
    }

    private var statusCardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
    }

    private var latestUpdateText: String {
        guard let date = model.moduleSummary.latestUpdatedAt else { return "尚未更新" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var automaticPublishText: String? {
        guard let runsAt = model.automaticPublishRunsAt else { return nil }
        return "自动发布已排队，预计 \(runsAt.formatted(date: .omitted, time: .shortened)) 执行"
    }

    private var workActivityStatusText: String {
        let title = model.workActivity.title
        let status = model.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !status.isEmpty, status != "准备就绪", status != title else { return title }
        return "\(title)：\(status)"
    }

    private var synchronizingModuleName: String? {
        guard let id = model.synchronizingModuleID else { return nil }
        return model.modules.first(where: { $0.id == id })?.name
    }

    private var synchronizationProgress: Double {
        guard model.synchronizationTotalCount > 0 else { return 0 }
        return min(
            max(Double(model.synchronizationCompletedCount) / Double(model.synchronizationTotalCount), 0),
            1
        )
    }

    private var synchronizationPercentage: Int {
        Int((synchronizationProgress * 100).rounded())
    }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $model.selectedModuleID) {
                if model.settings.combinedModuleEnabled {
                    Section {
                        CombinedModuleRow()
                            .tag(AppModel.combinedModuleSelectionID)
                    }
                }

                ForEach(sidebarSections) { section in
                    Section {
                        ForEach(section.modules) { module in
                            moduleRow(module)
                        }
                    } header: {
                        Label("\(section.title) \(section.modules.count)", systemImage: section.systemImage)
                            .font(.caption.weight(.medium))
                    }
                }
            }
            .overlay {
                if filteredModules.isEmpty {
                    ContentUnavailableView(
                        model.modules.isEmpty ? "还没有模块" : "没有搜索结果",
                        systemImage: "shippingbox",
                        description: Text(model.modules.isEmpty ? "添加第一个原始地址，Surge Relay 会生成模块输出。" : "换个关键词试试。")
                    )
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                statusCard
                    .background(.bar)
            }
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

    @ViewBuilder
    private func moduleRow(_ module: RelayModule) -> some View {
        HStack(spacing: 8) {
            if isBatchSelecting {
                Toggle("", isOn: batchSelectionBinding(for: module.id))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .disabled(!module.publishesStandalone)
                    .help(module.publishesStandalone ? "选择发布该模块" : "该模块未开启独立发布")
            }
            ModuleRow(module: module)
        }
            .tag(module.id)
            .contextMenu {
                Button("编辑") { presentEditor(module) }
                Divider()
                Button("删除", role: .destructive) { deleteCandidate = module }
            }
    }

    private func batchSelectionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { batchSelectedModuleIDs.contains(id) },
            set: { selected in
                if selected {
                    batchSelectedModuleIDs.insert(id)
                } else {
                    batchSelectedModuleIDs.remove(id)
                }
            }
        )
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

private struct ModuleRow: View {
    @Environment(AppModel.self) private var model
    let module: RelayModule

    var body: some View {
        HStack(spacing: 10) {
            ModuleIconView(module: module, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(module.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if module.state == .updating {
                ProgressView()
                    .controlSize(.small)
            } else {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .help(statusHelp)
            }
            if model.settings.combinedModuleEnabled {
                Toggle("包含", isOn: Binding(
                    get: { module.isEnabled },
                    set: { model.setModuleEnabled(id: module.id, enabled: $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
        }
        .padding(.vertical, 5)
        .opacity(model.settings.combinedModuleEnabled && !module.isEnabled ? 0.55 : 1)
    }

    private var subtitle: String {
        if module.state == .failed, let failureSummary {
            return "更新失败：\(failureSummary)"
        }
        var parts = [module.storageLocation.title, module.sourceOrigin.title]
        if !module.category.isEmpty { parts.append(module.category) }
        let folder = ModuleOutputFolder.normalized(module.outputFolder)
        if folder != ModuleOutputFolder.root {
            parts.append(ModuleOutputFolder.displayTitle(for: folder))
        }
        if !module.publishesStandalone { parts.append("不发布独立模块") }
        return parts.joined(separator: " · ")
    }

    private var failureSummary: String? {
        guard let error = module.lastError else { return nil }
        let summary = UpdateFailureFormatter.summary(from: error)
        return summary.isEmpty ? nil : summary
    }

    private var statusHelp: String {
        guard module.state == .failed, let failureSummary else { return module.state.title }
        return "\(module.state.title)：\(failureSummary)"
    }

    private var statusColor: Color {
        switch module.state {
        case .never: .secondary
        case .updating: .blue
        case .current: .green
        case .failed: .red
        }
    }
}
