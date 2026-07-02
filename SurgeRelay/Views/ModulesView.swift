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

    private var filteredModules: [RelayModule] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return model.modules }
        return model.modules.filter { searchableText(for: $0).contains(query) }
    }

    private func searchableText(for module: RelayModule) -> String {
        var parts = [
            module.name,
            module.sourceURL,
            module.outputFileName,
            module.sourceFormatDisplayTitle,
        ]
        parts.append(contentsOf: module.argumentOverrides.flatMap { [$0.key, $0.value] })
        if let data = try? JSONEncoder().encode(module.scriptHubOptions),
           let text = String(data: data, encoding: .utf8) {
            parts.append(text)
        }
        if let content = contentIndex[module.id] {
            parts.append(content)
        }
        return parts.joined(separator: "\n").lowercased()
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
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .animation(.snappy, value: model.workActivity)
        .animation(.snappy, value: model.presentedError)
        .animation(.snappy, value: model.automaticPublishRunsAt)
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

                Section {
                if searchText.isEmpty {
                    ForEach(model.modules) { module in
                        moduleRow(module)
                    }
                    .onMove { offsets, destination in
                        model.moveModules(fromOffsets: offsets, toOffset: destination)
                    }
                } else {
                    ForEach(filteredModules) { module in
                        moduleRow(module)
                    }
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
            .safeAreaInset(edge: .bottom) { statusCard }
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
            NavigationStack {
                SettingsView()
                    .environment(model)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { model.presentsSettings = false }
                        }
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
        ModuleRow(module: module)
            .tag(module.id)
            .contextMenu {
                Button("编辑") { presentEditor(module) }
                Divider()
                Button("删除", role: .destructive) { deleteCandidate = module }
            }
    }
}

private struct CombinedModuleRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 9) {
            Image("SummaryIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
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
        .padding(.vertical, 7)
    }

    private var summaryIconShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 28 * ModuleIconView.cornerRadiusRatio, style: .continuous)
    }
}

private struct CombinedModuleDetailView: View {
    @Environment(AppModel.self) private var model

    private var latestUpdateAt: Date? {
        model.modules.compactMap(\.lastUpdatedAt).max()
    }

    var body: some View {
        Form {
            Section("汇总模块") {
                detailRow("名称", value: "Surge Relay 汇总", icon: "square.stack.3d.up.fill")
                detailRow(
                    "包含来源",
                    value: "\(model.modules.filter(\.isEnabled).count) / \(model.modules.count)",
                    icon: "shippingbox"
                )
                detailRow(
                    "最新更新",
                    value: latestUpdateAt?.formatted(date: .long, time: .standard) ?? "尚未更新",
                    icon: "clock"
                )
            }

            if model.settings.storageMode == .local {
                Section("总模块文件") {
                    if let localURL = model.combinedLocalFileURL {
                        Text(localURL.path)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Section("总模块订阅地址") {
                    if let rawURL = model.combinedRawURL {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(rawURL.absoluteString)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            URLCopyButton(url: rawURL)
                        }
                    } else {
                        Label("完成发布配置后，这里会显示稳定订阅地址。", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            latestPublishSection
            publishPreviewSection
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var latestPublishSection: some View {
        if model.settings.storageMode == .gitHub, let publish = model.latestGitHubPublish {
            Section("最近 GitHub 发布") {
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
        if model.settings.storageMode == .gitHub || preview != nil {
            Section(model.settings.storageMode == .gitHub ? "GitHub 发布" : "本地清理") {
                if model.settings.storageMode == .gitHub {
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
                } else if model.settings.storageMode == .gitHub {
                    Label("发布前可预览新增、更新和删除的文件；包含删除项时会要求确认。", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var relevantPublishPreview: PublishPreview? {
        guard let preview = model.pendingPublishPreview else { return nil }
        switch (model.settings.storageMode, preview.destination) {
        case (.gitHub, .gitHub), (.local, .local):
            return preview
        default:
            return nil
        }
    }

    private func detailRow(_ label: String, value: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Label(label, systemImage: icon)
                .frame(width: 108, alignment: .leading)
            Text(value)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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

            List {
                if !candidates.isEmpty {
                    Section("可导入") {
                        ForEach(candidates.indices, id: \.self) { index in
                            importCandidateRow(index: index)
                        }
                    }
                }

                if !skippedFiles.isEmpty {
                    Section("已跳过") {
                        ForEach(skippedFiles) { file in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(file.relativePath)
                                    .font(.caption)
                                    .textSelection(.enabled)
                                Text(file.reason)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 5)
                        }
                    }
                }
            }
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

    private var selectionSummary: String {
        if hasInvalidSelection { return "已选择项需要填写名称" }
        guard !candidates.isEmpty else { return "没有可导入文件" }
        return "已选择 \(selectedCandidates.count) / \(candidates.count)"
    }

    private func importCandidateRow(index: Int) -> some View {
        let candidate = candidates[index]
        return HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: selectionBinding(forID: candidate.id))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 8) {
                Text(candidate.relativePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

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
            }
        }
        .padding(.vertical, 7)
        .opacity(selectedCandidateIDs.contains(candidate.id) ? 1 : 0.55)
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
        HStack(spacing: 9) {
            ModuleIconView(module: module, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(module.name).fontWeight(.medium).lineLimit(1)
                Text(module.sourceFormatDisplayTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if module.state == .updating {
                ProgressView()
                    .controlSize(.small)
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
}

private struct ModuleDetailView: View {
    @Environment(AppModel.self) private var model
    @State private var argumentInfo = ModuleArgumentInfo()
    let module: RelayModule
    let onEdit: () -> Void

    var body: some View {
        Form {
                Section("模块信息") {
                    detailRow("原始地址", value: module.sourceURL, icon: "link")
                    detailRow("来源格式", value: module.sourceFormatDisplayTitle, icon: "doc.text")
                    detailRow("独立模块", value: module.publishesStandalone ? "发布" : "不发布", icon: "doc.badge.gearshape")
                    if model.settings.combinedModuleEnabled {
                        detailRow("总模块", value: module.isEnabled ? "包含" : "不包含", icon: "square.stack.3d.up")
                        detailRow(
                            model.settings.storageMode == .local ? "汇总文件" : "汇总订阅",
                            value: combinedOutputLocation,
                            icon: "square.stack.3d.up"
                        )
                    }
                    detailRow("上次更新", value: module.lastUpdatedAt?.formatted(date: .long, time: .standard) ?? "从未更新", icon: "clock")
                    Button("编辑模块…", systemImage: "pencil", action: onEdit)
                }

                if let summary = module.scriptHubOptions.configuredSummary {
                    Section("高级设置") {
                        Label {
                            Text(summary)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        } icon: {
                            Image(systemName: "slider.horizontal.3")
                        }
                    }
                }

                if !argumentInfo.definitions.isEmpty {
                    Section("模块参数") {
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

                if model.settings.storageMode == .gitHub {
                    Section(model.settings.github.repositoryIsPrivate == true ? "Cloudflare" : "GitHub") {
                        if !module.publishesStandalone {
                            Label("该模块未开启独立发布。", systemImage: "pause.circle")
                                .foregroundStyle(.secondary)
                        } else if let rawURL = model.rawURL(for: module) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(rawURL.absoluteString)
                                    .font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled)
                                HStack {
                                    URLCopyButton(url: rawURL)
                                }
                            }
                        } else {
                            Label("完成发布配置后，这里会出现该模块自己的稳定地址。", systemImage: "info.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let error = module.lastError {
                    Section("最近一次更新失败") {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("更新失败", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(error).textSelection(.enabled)
                            Text(failureCacheNote)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if module.hasOverrideConflict {
                    Section("本地编辑冲突") {
                        Label("上游模块已经变化，本地编辑仍在使用。请前往“预览”比较后决定保留或恢复。", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

        }
        .formStyle(.grouped)
        .task(id: "\(module.id.uuidString)-\(module.contentHash ?? "")") {
            argumentInfo = await model.moduleArgumentInfo(for: module)
        }
    }

    private var combinedOutputLocation: String {
        if let localURL = model.combinedLocalFileURL { return localURL.path }
        return model.combinedRawURL?.absoluteString ?? "等待 GitHub 发布配置"
    }

    private var failureCacheNote: String {
        model.settings.combinedModuleEnabled
            ? "如果该来源有缓存，总模块会继续沿用它上一次成功版本。"
            : "如果该来源有缓存，模块输出会继续沿用它上一次成功版本。"
    }

    @ViewBuilder
    private func argumentControl(_ definition: ModuleArgumentDefinition) -> some View {
        let value = argumentValue(for: definition)
        if ["true", "false"].contains(definition.defaultValue.lowercased()) {
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
            .toggleStyle(.switch)
        } else {
            LabeledContent(definition.key) {
                TextField(
                    "",
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

    private func detailRow(_ label: String, value: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Label(label, systemImage: icon)
                .frame(width: 108, alignment: .leading)
            Text(value)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
