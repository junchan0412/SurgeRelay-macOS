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
            module.publishesStandalone ? "独立模块" : "不发布独立模块",
            module.state.title,
        ]
        if let iconURL = module.iconURL { parts.append(iconURL) }
        if let customIconURL = module.customIconURL { parts.append(customIconURL) }
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

    private var filteredModules: [RelayModule] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
                id: "remote",
                title: "可更新",
                systemImage: "arrow.triangle.2.circlepath",
                modules: values.filter { module in
                    module.state != .failed && !module.hasOverrideConflict && hasRemoteSource(module)
                }
            ),
            SidebarModuleSection(
                id: "local",
                title: "本地来源",
                systemImage: "folder",
                modules: values.filter { module in
                    module.state != .failed && !module.hasOverrideConflict && hasLocalSource(module)
                }
            ),
            SidebarModuleSection(
                id: "missing",
                title: "缺少有效来源",
                systemImage: "link.badge.plus",
                modules: values.filter { module in
                    module.state != .failed && !module.hasOverrideConflict && !hasRemoteSource(module) && !hasLocalSource(module)
                }
            )
        ].filter { !$0.modules.isEmpty }
    }

    private func hasRemoteSource(_ module: RelayModule) -> Bool {
        module.hasRemoteOriginalSource
    }

    private func hasLocalSource(_ module: RelayModule) -> Bool {
        !module.hasRemoteOriginalSource && URL(string: module.sourceURL)?.isFileURL == true
    }

    private func searchableText(for module: RelayModule) -> String {
        ModuleSearchIndex.text(for: module, cachedContent: contentIndex[module.id])
    }

    private var contentIndexToken: String {
        model.modules.map { "\($0.id.uuidString)\($0.contentHash ?? "")" }.joined()
    }

    private func rebuildContentIndex() async {
        var index: [UUID: String] = [:]
        for module in model.modules {
            if let content = try? await model.previewContent(for: module) {
                index[module.id] = content.lowercased()
            }
        }
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
        guard let date = model.modules.compactMap(\.lastUpdatedAt).max() else { return "尚未更新" }
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

private struct ModuleDetailMetadataPill: Identifiable {
    let title: String
    let systemImage: String

    var id: String { "\(systemImage)|\(title)" }
}

private struct ModuleDetailSummaryMetric: Identifiable {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var id: String { "\(systemImage)|\(title)|\(value)" }
}

private struct DetailInfoSection<Content: View>: View {
    let title: String
    private let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.18), lineWidth: 0.5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DetailInfoRow: View {
    let label: String
    let value: String
    let icon: String
    var monospaced = false
    var copyValue: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)
            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .frame(width: 104, alignment: .leading)
            valueContent
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.16))
                .frame(height: 0.5)
                .padding(.leading, 32)
        }
    }

    @ViewBuilder
    private var valueContent: some View {
        if let copyValue {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    valueText(fixedHorizontal: true)
                    TextCopyButton(text: copyValue)
                        .layoutPriority(1)
                }
                VStack(alignment: .leading, spacing: 8) {
                    valueText(fixedHorizontal: false)
                    TextCopyButton(text: copyValue)
                }
            }
        } else {
            valueText(fixedHorizontal: false)
        }
    }

    private func valueText(fixedHorizontal: Bool) -> some View {
        Text(value)
            .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(fixedHorizontal ? 1 : (monospaced ? 3 : nil))
            .truncationMode(.middle)
            .fixedSize(horizontal: fixedHorizontal, vertical: true)
            .frame(maxWidth: fixedHorizontal ? nil : .infinity, alignment: .leading)
    }
}

private struct DetailControlRow<Content: View>: View {
    let label: String
    let icon: String
    private let content: () -> Content

    init(label: String, icon: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.icon = icon
        self.content = content
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)
            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .frame(width: 104, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.16))
                .frame(height: 0.5)
                .padding(.leading, 32)
        }
    }
}

private struct CombinedModuleRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image("SummaryIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
                .clipShape(summaryIconShape)
                .overlay {
                    summaryIconShape
                        .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text("Surge Relay 汇总")
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text("\(model.modules.filter(\.isEnabled).count) 个来源 · 总模块订阅")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 5)
    }

    private var summaryIconShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 32 * ModuleIconView.cornerRadiusRatio, style: .continuous)
    }
}

private struct CombinedModuleDetailView: View {
    @Environment(AppModel.self) private var model

    private var includedModules: [RelayModule] {
        model.modules.filter(\.isEnabled)
    }

    private var standaloneModules: [RelayModule] {
        model.modules.filter(\.publishesStandalone)
    }

    private var failedModules: [RelayModule] {
        model.modules.filter { $0.state == .failed }
    }

    private var latestUpdateAt: Date? {
        model.modules.compactMap(\.lastUpdatedAt).max()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                summaryHeader
                contentSection
                outputSection
                latestPublishSection
                publishPreviewSection
            }
            .frame(maxWidth: 760, alignment: .topLeading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var summaryHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            Image("SummaryIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 56 * ModuleIconView.cornerRadiusRatio, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                Text("Surge Relay 汇总")
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { summaryPills }
                    VStack(alignment: .leading, spacing: 6) { summaryPills }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.24), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var summaryPills: some View {
        metadataPill("\(includedModules.count) 个来源", systemImage: "shippingbox")
        if model.settings.publishToLocal {
            metadataPill("本地发布", systemImage: "folder")
        }
        if model.settings.publishToGitHub {
            metadataPill("GitHub 发布", systemImage: "cloud")
        }
        if !failedModules.isEmpty {
            metadataPill("\(failedModules.count) 个失败", systemImage: "exclamationmark.triangle", isWarning: true)
        }
    }

    private var contentSection: some View {
        detailSection("汇总内容") {
            detailRow("包含来源", value: "\(includedModules.count) / \(model.modules.count)", icon: "shippingbox")
            detailRow("独立模块", value: "\(standaloneModules.count) 个同时单独发布", icon: "doc.badge.gearshape")
            detailRow("最新更新", value: latestUpdateAt?.formatted(date: .long, time: .standard) ?? "尚未更新", icon: "clock")
            detailRow(
                "总模块文件",
                value: FilenameSanitizer.sgmoduleName(from: model.settings.combinedModuleFileName),
                icon: "square.stack.3d.up",
                monospaced: true
            )
        }
    }

    private var outputSection: some View {
        detailSection("总模块输出") {
            if model.settings.publishToLocal {
                if let localURL = model.combinedLocalFileURL {
                    detailRow("文件位置", value: localURL.path, icon: "doc", monospaced: true, copyValue: localURL.path)
                } else {
                    Label("等待本地模块根目录配置。", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
            if model.settings.publishToGitHub {
                if let rawURL = model.combinedRawURL {
                    detailRow("GitHub 订阅", value: rawURL.absoluteString, icon: "link", monospaced: true, copyValue: rawURL.absoluteString)
                } else {
                    Label("完成 GitHub 发布配置后，这里会显示稳定订阅地址。", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var latestPublishSection: some View {
        if model.settings.publishToGitHub, let publish = model.latestGitHubPublish {
            detailSection("最近 GitHub 发布") {
                detailRow("提交", value: publish.commitDisplay, icon: "arrow.triangle.branch")
                detailRow("时间", value: publish.date.formatted(date: .long, time: .standard), icon: "clock")
                detailRow("变更", value: publish.fileSummary, icon: "doc.on.doc")
                if let commitURL = publish.commitURL.flatMap(URL.init(string:)) {
                    Link(destination: commitURL) {
                        Label("打开 Commit", systemImage: "arrow.up.right.square")
                    }
                }
                if publish.changedFileCount > 0 {
                    DisclosureGroup("文件清单") {
                        publishFileList("上传/更新", files: publish.publishedFiles, systemImage: "arrow.up.doc")
                        publishFileList("删除", files: publish.deletedFiles, systemImage: "trash", isDestructive: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var publishPreviewSection: some View {
        let preview = relevantPublishPreview
        if model.settings.publishToGitHub || preview != nil {
            detailSection("发布与清理") {
                if model.settings.publishToGitHub {
                    Button("预览发布…", systemImage: "square.and.arrow.up") {
                        Task { await model.previewPublish() }
                    }
                    .disabled(model.isWorking || !model.settings.github.isConfigured || model.githubToken.isEmpty)
                }

                if let preview {
                    PublishPreviewSummaryView(preview: preview)
                    HStack {
                        Button(preview.destination == .gitHub ? "确认发布" : "删除旧文件", systemImage: "checkmark.circle") {
                            Task { await model.confirmPendingPublish() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isWorking || !preview.hasChanges)

                        Button("取消预览", role: .cancel) {
                            model.dismissPendingPublishPreview()
                        }
                        .disabled(model.isWorking)
                    }
                } else if model.settings.publishToGitHub {
                    Label("发布前可预览新增、更新和删除的文件；包含删除项时会要求确认。", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var relevantPublishPreview: PublishPreview? {
        guard let preview = model.pendingPublishPreview else { return nil }
        if preview.destination == .gitHub { return model.settings.publishToGitHub ? preview : nil }
        if preview.destination == .local { return model.settings.publishToLocal ? preview : nil }
        return nil
    }

    private func metadataPill(_ title: String, systemImage: String, isWarning: Bool = false) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(isWarning ? .orange : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.45), in: Capsule())
    }

    private func detailSection<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        DetailInfoSection(title, content: content)
    }

    private func detailRow(
        _ label: String,
        value: String,
        icon: String,
        monospaced: Bool = false,
        copyValue: String? = nil
    ) -> some View {
        DetailInfoRow(label: label, value: value, icon: icon, monospaced: monospaced, copyValue: copyValue)
    }
}

private struct PublishPreviewSummaryView: View {
    let preview: PublishPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            detail("目标", value: preview.targetDescription)
            detail("结果清单", value: "\(preview.activeFiles.count) 个文件")
            if preview.hasChanges {
                if !preview.changedFiles.isEmpty {
                    fileList("将上传/写入", files: preview.changedFiles)
                }
                if !preview.deletedFiles.isEmpty {
                    fileList("将删除", files: preview.deletedFiles, isDestructive: true)
                }
            } else {
                Label("没有文件变化", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detail(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.medium))
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }

    private func fileList(_ title: String, files: [String], isDestructive: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("\(title) \(files.count) 个文件", systemImage: isDestructive ? "trash" : "arrow.up.doc")
                .font(.caption.weight(.medium))
                .foregroundStyle(isDestructive ? .orange : .primary)
            ForEach(Array(files.prefix(8)), id: \.self) { file in
                Text(file)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if files.count > 8 {
                Text("另有 \(files.count - 8) 个文件")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private func publishFileList(
    _ title: String,
    files: [String],
    systemImage: String,
    isDestructive: Bool = false
) -> some View {
    Group {
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Label("\(title) \(files.count) 个文件", systemImage: systemImage)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isDestructive ? .orange : .primary)
                ForEach(Array(files.prefix(10)), id: \.self) { file in
                    Text(file)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if files.count > 10 {
                    Text("另有 \(files.count - 10) 个文件")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
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

private struct LocalModuleImportPreviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedCandidateIDs: Set<String>
    @State private var candidates: [LocalModuleScanCandidate]
    private let skippedFiles: [LocalModuleScanSkippedFile]
    @State private var isImporting = false

    init(
        candidates: [LocalModuleScanCandidate],
        skippedFiles: [LocalModuleScanSkippedFile],
        selectedCandidateIDs: Binding<Set<String>>
    ) {
        _candidates = State(initialValue: candidates)
        self.skippedFiles = skippedFiles
        _selectedCandidateIDs = selectedCandidateIDs
    }

    private var selectedCandidates: [LocalModuleScanCandidate] {
        candidates.filter { selectedCandidateIDs.contains($0.id) }
    }

    private var hasInvalidSelection: Bool {
        selectedCandidates.contains { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("导入本地模块").font(.title2.bold())
                Text("发现 \(candidates.count) 个可导入文件，跳过 \(skippedFiles.count) 个文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    importSummaryCard
                    if !candidates.isEmpty {
                        importSection("可导入") {
                            ForEach(candidates.indices, id: \.self) { index in
                                importCandidateCard(index: index)
                            }
                        }
                    }
                    if !skippedFiles.isEmpty {
                        skippedFilesSection
                    }
                    if candidates.isEmpty && skippedFiles.isEmpty {
                        ContentUnavailableView("没有可导入文件", systemImage: "folder")
                            .frame(maxWidth: .infinity, minHeight: 260)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.visible)
            .frame(minHeight: 300)

            Divider()

            HStack {
                Button("全选") {
                    selectedCandidateIDs = Set(candidates.map(\.id))
                }
                Button("全不选") {
                    selectedCandidateIDs.removeAll()
                }
                Spacer()
                Text(selectionSummary)
                    .font(.caption)
                    .foregroundStyle(hasInvalidSelection ? .red : .secondary)
                Button("取消", role: .cancel) { dismiss() }
                Button("导入") {
                    Task { await importSelectedCandidates() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedCandidates.isEmpty || hasInvalidSelection || isImporting || model.isWorking)
            }
            .padding(20)
        }
        .frame(width: 780, height: 560)
    }

    private var importSummaryCard: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 52, height: 52)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                Text("本地模块扫描")
                    .font(.title3.weight(.semibold))
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { summaryPills }
                    VStack(alignment: .leading, spacing: 6) { summaryPills }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.24), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var summaryPills: some View {
        importPill("\(candidates.count) 个可导入", systemImage: "doc.text")
        importPill("\(selectedCandidates.count) 个已选择", systemImage: "checkmark.circle")
        if !skippedFiles.isEmpty {
            importPill("\(skippedFiles.count) 个跳过", systemImage: "exclamationmark.triangle", isWarning: true)
        }
    }

    private var selectionSummary: String {
        if hasInvalidSelection { return "已选择项需要填写名称" }
        guard !candidates.isEmpty else { return "没有可导入文件" }
        return "已选择 \(selectedCandidates.count) / \(candidates.count)"
    }

    private var skippedFilesSection: some View {
        importSection("已跳过") {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(skippedFiles) { file in
                        skippedFileRow(file)
                    }
                }
                .padding(.top, 6)
            } label: {
                Label("\(skippedFiles.count) 个文件", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func importCandidateCard(index: Int) -> some View {
        let candidate = candidates[index]
        let isSelected = selectedCandidateIDs.contains(candidate.id)
        return HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: selectionBinding(forID: candidate.id))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .padding(.top, 14)

            Image(systemName: "doc.text")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isSelected ? .secondary : .tertiary)
                .frame(width: 34, height: 34)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.top, 7)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名模块" : candidate.name)
                        .font(.headline)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .lineLimit(1)
                    Text(candidate.relativePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("名称")
                            .foregroundStyle(.secondary)
                        TextField("模块名称", text: textBinding(index: index, keyPath: \.name))
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("标签")
                            .foregroundStyle(.secondary)
                        TextField("Surge category", text: textBinding(index: index, keyPath: \.category))
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("文件夹")
                            .foregroundStyle(.secondary)
                        Picker("", selection: outputFolderBinding(index: index)) {
                            ForEach(outputFolderOptions(preserving: candidate.outputFolder), id: \.self) { folder in
                                Text(ModuleOutputFolder.displayTitle(for: folder)).tag(folder)
                            }
                        }
                        .labelsHidden()
                    }
                }
                .font(.callout)
                .disabled(!isSelected)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(isSelected ? 0.22 : 0.12), lineWidth: 0.5)
        }
        .opacity(isSelected ? 1 : 0.58)
    }

    private func skippedFileRow(_ file: LocalModuleScanSkippedFile) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.relativePath)
                    .font(.caption)
                    .textSelection(.enabled)
                Text(file.reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func importPill(_ title: String, systemImage: String, isWarning: Bool = false) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(isWarning ? .orange : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.45), in: Capsule())
    }

    private func importSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectionBinding(forID id: String) -> Binding<Bool> {
        Binding(
            get: { selectedCandidateIDs.contains(id) },
            set: { isSelected in
                if isSelected {
                    selectedCandidateIDs.insert(id)
                } else {
                    selectedCandidateIDs.remove(id)
                }
            }
        )
    }

    private func textBinding(index: Int, keyPath: WritableKeyPath<LocalModuleScanCandidate, String>) -> Binding<String> {
        Binding(
            get: { candidates[index][keyPath: keyPath] },
            set: { candidates[index][keyPath: keyPath] = $0 }
        )
    }

    private func outputFolderBinding(index: Int) -> Binding<String> {
        Binding(
            get: { ModuleOutputFolder.normalized(candidates[index].outputFolder) },
            set: { candidates[index].outputFolder = $0 }
        )
    }

    private func outputFolderOptions(preserving selected: String) -> [String] {
        ModuleOutputFolder.options(
            from: model.moduleOutputFolderOptions(preserving: selected) + candidates.map(\.outputFolder),
            preserving: selected
        )
    }

    private func importSelectedCandidates() async {
        let selected = selectedCandidates
        guard !selected.isEmpty, !hasInvalidSelection else { return }
        isImporting = true
        await model.importLocalModules(selected)
        isImporting = false
        dismiss()
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
                    .help(module.state.title)
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
        var parts = [module.sourceFormatDisplayTitle]
        if !module.category.isEmpty { parts.append(module.category) }
        let folder = ModuleOutputFolder.normalized(module.outputFolder)
        if folder != ModuleOutputFolder.root {
            parts.append(ModuleOutputFolder.displayTitle(for: folder))
        }
        if !module.publishesStandalone { parts.append("不发布独立模块") }
        return parts.joined(separator: " · ")
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

private struct ModuleDetailView: View {
    @Environment(AppModel.self) private var model
    @State private var argumentInfo = ModuleArgumentInfo()
    let module: RelayModule
    let onEdit: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                moduleSummaryHeader
                sourceAndOutputSection
                synchronizationSection
                advancedSection
                argumentsSection
                publishingSection
                diagnosticsSection
            }
            .frame(maxWidth: 760, alignment: .topLeading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .task(id: "\(module.id.uuidString)-\(module.contentHash ?? "")") {
            argumentInfo = await model.moduleArgumentInfo(for: module)
        }
    }

    private var moduleSummaryHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                ModuleIconView(module: module, size: 56)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(module.name)
                            .font(.title2.weight(.semibold))
                            .lineLimit(2)
                            .textSelection(.enabled)
                        metadataPillLayout
                    }
                    Spacer(minLength: 0)
                    Button("编辑模块…", systemImage: "pencil", action: onEdit)
                }
            }
            summaryMetricLayout
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.24), lineWidth: 0.5)
        }
    }

    private var sourceAndOutputSection: some View {
        detailSection("来源与输出") {
            detailRow("原始地址", value: sourceAddressDisplay, icon: "link", monospaced: true, copyValue: sourceAddressCopyValue)
            detailRow("来源格式", value: module.sourceFormatDisplayTitle, icon: "doc.text")
            if let subscription = module.scriptHubSubscription {
                detailRow("来源记录", value: subscription.displaySummary, icon: "point.3.connected.trianglepath.dotted")
                detailRow("模块链接", value: subscription.subscriptionURL, icon: "link.badge.plus", monospaced: true, copyValue: subscription.subscriptionURL)
                if let outputName = subscription.outputName {
                    detailRow("原输出名", value: outputName, icon: "doc.text", monospaced: true)
                }
            }
            detailRow("模块标签", value: module.category.isEmpty ? "未设置" : module.category, icon: "tag")
            detailRow("存放文件夹", value: ModuleOutputFolder.displayTitle(for: module.outputFolder), icon: "folder")
            detailRow(
                "输出文件",
                value: module.publishesStandalone ? module.publishedRelativePath : "未开启独立发布",
                icon: "doc.badge.gearshape",
                monospaced: module.publishesStandalone,
                copyValue: module.publishesStandalone ? module.publishedRelativePath : nil
            )
            detailRow("图标来源", value: iconSourceDescription, icon: "photo")
            if let iconURLDisplay {
                detailRow("图标地址", value: iconURLDisplay, icon: "link", monospaced: true, copyValue: iconURLDisplay)
            }
        }
    }

    private var synchronizationSection: some View {
        detailSection("同步状态") {
            detailRow("更新状态", value: module.state.title, icon: statusIcon)
            detailRow("创建时间", value: module.createdAt.formatted(date: .long, time: .standard), icon: "calendar")
            detailRow("上次更新", value: module.lastUpdatedAt?.formatted(date: .long, time: .standard) ?? "从未更新", icon: "clock")
            detailRow("来源检查", value: module.sourceCheckedAt?.formatted(date: .long, time: .standard) ?? "尚未检查", icon: "dot.radiowaves.left.and.right")
            detailRow(
                "内容 hash",
                value: module.contentHash.map { String($0.prefix(12)) } ?? "尚未生成",
                icon: "number",
                monospaced: true,
                copyValue: module.contentHash
            )
            if let sourceContentHash = module.sourceContentHash {
                detailRow("来源 hash", value: String(sourceContentHash.prefix(12)), icon: "number", monospaced: true, copyValue: sourceContentHash)
            }
            if let sourceETag = module.sourceETag {
                detailRow("来源 ETag", value: sourceETag, icon: "tag", monospaced: true, copyValue: sourceETag)
            }
            if let sourceLastModified = module.sourceLastModified {
                detailRow("来源修改时间", value: sourceLastModified, icon: "calendar.badge.clock", monospaced: true)
            }
            detailRow(
                "转换引擎",
                value: module.conversionEngineRevision.map { String($0.prefix(12)) } ?? "原生 Surge 模块",
                icon: "cpu",
                monospaced: module.conversionEngineRevision != nil,
                copyValue: module.conversionEngineRevision
            )
            if model.settings.combinedModuleEnabled {
                detailRow("总模块", value: module.isEnabled ? "包含" : "不包含", icon: "square.stack.3d.up")
                detailRow(
                    "汇总输出",
                    value: combinedOutputLocation,
                    icon: "square.stack.3d.up",
                    monospaced: true,
                    copyValue: combinedOutputCopyValue
                )
            }
        }
    }

    @ViewBuilder
    private var advancedSection: some View {
        if let summary = module.scriptHubOptions.configuredSummary {
            detailSection("高级设置") {
                Label {
                    Text(summary)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "slider.horizontal.3")
                }
            }
        }
    }

    @ViewBuilder
    private var argumentsSection: some View {
        if !argumentInfo.definitions.isEmpty {
            detailSection("模块参数") {
                ForEach(argumentInfo.definitions) { definition in
                    argumentControl(definition)
                }
                HStack {
                    Text("修改会立即应用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("恢复默认值") {
                        model.resetModuleArguments(moduleID: module.id)
                    }
                    .disabled(module.argumentOverrides.isEmpty)
                }
                if let help = argumentInfo.helpText {
                    DisclosureGroup("参数说明") {
                        Text(help)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var publishingSection: some View {
        if model.settings.publishToGitHub {
            detailSection(model.settings.github.repositoryIsPrivate == true ? "Cloudflare" : "GitHub") {
                if !module.publishesStandalone {
                    Label("该模块未开启独立发布。", systemImage: "pause.circle")
                        .foregroundStyle(.secondary)
                } else if let rawURL = model.rawURL(for: module) {
                    detailRow("订阅地址", value: rawURL.absoluteString, icon: "link", monospaced: true, copyValue: rawURL.absoluteString)
                } else {
                    Label("完成发布配置后，这里会出现该模块自己的稳定地址。", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        if model.settings.publishToLocal, module.publishesStandalone {
            detailSection("本地文件") {
                detailRow("文件位置", value: localPublishedPath, icon: "doc", monospaced: true, copyValue: localPublishedPath)
            }
        }
    }

    @ViewBuilder
    private var diagnosticsSection: some View {
        if let error = module.lastError {
            detailSection("最近一次更新失败") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("更新失败", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error).textSelection(.enabled)
                    Text(failureCacheNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        if module.hasOverrideConflict {
            detailSection("本地编辑冲突") {
                Label("上游模块已经变化，本地编辑仍在使用。请前往“预览”比较后决定保留或恢复。", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var combinedOutputLocation: String {
        var values: [String] = []
        if let localURL = model.combinedLocalFileURL {
            values.append(localURL.path)
        }
        if let rawURL = model.combinedRawURL {
            values.append(rawURL.absoluteString)
        }
        return values.isEmpty ? "等待发布配置" : values.joined(separator: "\n")
    }

    private var combinedOutputCopyValue: String? {
        combinedOutputLocation == "等待发布配置" ? nil : combinedOutputLocation
    }

    private var localPublishedPath: String {
        URL(filePath: model.settings.localModuleDirectory, directoryHint: .isDirectory)
            .appending(path: module.publishedRelativePath)
            .path
    }

    private var iconSourceDescription: String {
        if module.customIconURL != nil {
            return "自定义图标（仅展示）"
        }
        if module.iconURL != nil {
            return "来源元数据（仅展示）"
        }
        return "默认图标"
    }

    private var iconURLDisplay: String? {
        module.customIconURL ?? module.iconURL
    }

    private var sourceAddressDisplay: String {
        let sourceURL = module.effectiveOriginalSourceURL
        if let url = URL(string: sourceURL), url.isFileURL {
            return url.path
        }
        return sourceURL.removingPercentEncoding ?? sourceURL
    }

    private var sourceAddressCopyValue: String {
        let sourceURL = module.effectiveOriginalSourceURL
        if let url = URL(string: sourceURL), url.isFileURL {
            return url.path
        }
        return sourceURL
    }

    private var statusIcon: String {
        switch module.state {
        case .never: "circle"
        case .updating: "arrow.triangle.2.circlepath"
        case .current: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var failureCacheNote: String {
        model.settings.combinedModuleEnabled
            ? "如果该来源有缓存，总模块会继续沿用它上一次成功版本。"
            : "如果该来源有缓存，模块输出会继续沿用它上一次成功版本。"
    }

    private var metadataPills: [ModuleDetailMetadataPill] {
        var pills = [
            ModuleDetailMetadataPill(title: module.sourceFormatDisplayTitle, systemImage: "doc.text")
        ]
        if !module.category.isEmpty {
            pills.append(ModuleDetailMetadataPill(title: module.category, systemImage: "tag"))
        }
        if module.scriptHubSubscription != nil {
            pills.append(ModuleDetailMetadataPill(title: "Script-Hub", systemImage: "link"))
        }
        let folder = ModuleOutputFolder.normalized(module.outputFolder)
        if folder != ModuleOutputFolder.root {
            pills.append(ModuleDetailMetadataPill(
                title: ModuleOutputFolder.displayTitle(for: folder),
                systemImage: "folder"
            ))
        }
        pills.append(ModuleDetailMetadataPill(
            title: module.publishesStandalone ? "独立发布" : "不发布独立模块",
            systemImage: module.publishesStandalone ? "checkmark.circle" : "pause.circle"
        ))
        if model.settings.combinedModuleEnabled {
            pills.append(ModuleDetailMetadataPill(
                title: module.isEnabled ? "包含在总模块" : "不进总模块",
                systemImage: "square.stack.3d.up"
            ))
        }
        return pills
    }

    private var summaryMetrics: [ModuleDetailSummaryMetric] {
        [
            ModuleDetailSummaryMetric(
                title: "输出",
                value: summaryOutputValue,
                systemImage: module.publishesStandalone ? "doc.badge.gearshape" : "pause.circle",
                tint: .secondary
            ),
            ModuleDetailSummaryMetric(
                title: "更新",
                value: summaryUpdateValue,
                systemImage: statusIcon,
                tint: statusColor
            ),
            ModuleDetailSummaryMetric(
                title: "图标",
                value: iconSourceDescription,
                systemImage: module.iconURL == nil ? "shippingbox" : "photo",
                tint: .secondary
            )
        ]
    }

    private var summaryOutputValue: String {
        guard module.publishesStandalone else { return "不发布独立模块" }
        return module.publishedRelativePath
    }

    private var summaryUpdateValue: String {
        if let lastUpdatedAt = module.lastUpdatedAt {
            return lastUpdatedAt.formatted(date: .abbreviated, time: .shortened)
        }
        return module.state.title
    }

    private var statusColor: Color {
        switch module.state {
        case .never: .secondary
        case .updating: .blue
        case .current: .green
        case .failed: .red
        }
    }

    private var summaryMetricLayout: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 152), spacing: 8, alignment: .top)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(summaryMetrics) { metric in
                summaryMetric(metric)
            }
        }
    }

    private func summaryMetric(_ metric: ModuleDetailSummaryMetric) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: metric.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(metric.tint)
                .frame(width: 18, height: 18)
                .background(metric.tint.opacity(0.14), in: .rect(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(metric.title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                Text(metric.value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var metadataPillLayout: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                StatusPill(state: module.state)
                ForEach(metadataPills) { pill in
                    metadataPill(pill.title, systemImage: pill.systemImage)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                StatusPill(state: module.state)
                ForEach(metadataPills) { pill in
                    metadataPill(pill.title, systemImage: pill.systemImage)
                }
            }
        }
    }

    private func metadataPill(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.45), in: Capsule())
    }

    private func detailSection<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        DetailInfoSection(title, content: content)
    }

    @ViewBuilder
    private func argumentControl(_ definition: ModuleArgumentDefinition) -> some View {
        let value = argumentValue(for: definition)
        if ["true", "false"].contains(definition.defaultValue.lowercased()) {
            DetailControlRow(label: definition.key, icon: "switch.2") {
                Toggle(definition.key, isOn: Binding(
                    get: { argumentValue(for: definition).lowercased() == "true" },
                    set: { enabled in
                        model.setModuleArgument(
                            moduleID: module.id,
                            key: definition.key,
                            value: enabled ? "true" : "false",
                            defaultValue: definition.defaultValue
                        )
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        } else {
            DetailControlRow(label: definition.key, icon: "text.cursor") {
                TextField(
                    definition.key,
                    text: Binding(
                        get: { argumentValue(for: definition) },
                        set: { newValue in
                            model.setModuleArgument(
                                moduleID: module.id,
                                key: definition.key,
                                value: newValue,
                                defaultValue: definition.defaultValue
                            )
                        }
                    ),
                    prompt: Text(definition.defaultValue)
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 180)
            }
            .help("默认值：\(definition.defaultValue)；当前值：\(value)")
        }
    }

    private func argumentValue(for definition: ModuleArgumentDefinition) -> String {
        model.modules.first(where: { $0.id == module.id })?.argumentOverrides[definition.key]
            ?? definition.defaultValue
    }

    private func detailRow(
        _ label: String,
        value: String,
        icon: String,
        monospaced: Bool = false,
        copyValue: String? = nil
    ) -> some View {
        DetailInfoRow(label: label, value: value, icon: icon, monospaced: monospaced, copyValue: copyValue)
    }
}
