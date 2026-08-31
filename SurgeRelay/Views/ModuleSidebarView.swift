import AppKit
import SwiftUI

struct ModuleSidebarView: View {
    @Environment(AppModel.self) private var model
    @SceneStorage("ModuleSidebarView.collapsedSectionIDs") private var collapsedSectionIDsRaw = ""
    let sections: [ModuleSidebarSection]
    let filteredModulesAreEmpty: Bool
    let allModulesAreEmpty: Bool
    let combinedModuleEnabled: Bool
    let filterCounts: [ModuleFilter: Int]
    let resultCount: Int
    let hasSearchQuery: Bool
    @Binding var searchText: String
    @Binding var sidebarFilter: ModuleFilter
    @Binding var sortOrder: ModuleSortOrder
    @Binding var isBatchSelecting: Bool
    @Binding var batchSelectedModuleIDs: Set<UUID>
    @Binding var deleteCandidate: ModuleDeleteCandidate?
    let editModule: (RelayModule) -> Void
    let textEditModule: (RelayModule) -> Void

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            ModuleSidebarFilterBar(
                selection: $sidebarFilter,
                sortOrder: $sortOrder,
                counts: filterCounts,
                resultCount: resultCount
            )
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

            List(selection: $model.selectedModuleID) {
                if combinedModuleEnabled {
                    Section {
                        CombinedModuleRow()
                            .tag(AppModel.combinedModuleSelectionID)
                    }
                }

                ForEach(sections) { section in
                    moduleSection(section)
                }
            }
            .listStyle(.sidebar)
            .animation(.snappy(duration: 0.2), value: sections.map(\.id))
            .animation(.snappy(duration: 0.2), value: collapsedSectionIDsRaw)
            .overlay {
                if filteredModulesAreEmpty {
                    ContentUnavailableView {
                        Label(emptyStateTitle, systemImage: "shippingbox")
                    } description: {
                        Text(emptyStateDescription)
                    } actions: {
                        if !allModulesAreEmpty && (sidebarFilter != .all || hasSearchQuery) {
                            Button("清除筛选与搜索") {
                                withAnimation(.snappy(duration: 0.2)) {
                                    sidebarFilter = .all
                                    searchText = ""
                                }
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ModuleSidebarStatusCard()
                .background(.bar)
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "搜索模块")
    }

    private var emptyStateTitle: String {
        if allModulesAreEmpty { return "还没有模块" }
        if hasSearchQuery && sidebarFilter != .all { return "没有符合搜索与筛选条件的模块" }
        if hasSearchQuery { return "没有搜索结果" }
        if sidebarFilter != .all { return "没有符合“\(sidebarFilter.title)”的模块" }
        return "没有符合筛选条件的模块"
    }

    private var emptyStateDescription: String {
        if allModulesAreEmpty { return "添加第一个更新地址，或扫描现有本地模块。" }
        if sidebarFilter != .all { return "可点击“清除筛选”或“全部”查看所有模块。" }
        if hasSearchQuery { return "换个关键词试试。" }
        return "可切换“全部”或其他筛选条件。"
    }

    @ViewBuilder
    private func moduleSection(_ section: ModuleSidebarSection) -> some View {
        let isExpanded = isSectionExpanded(section.id)
        Section {
            ModuleSidebarSectionHeader(
                title: section.title,
                count: section.modules.count,
                systemImage: section.systemImage,
                isExpanded: isExpanded
            ) {
                setSection(section.id, expanded: !isExpanded)
            }
            .listRowSeparator(.hidden)

            if isExpanded {
                ForEach(section.modules) { module in
                    moduleRow(module)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity
                        ))
                }
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
                    .help("勾选后随“发布所选”发布到该模块的存放位置")
                    .accessibilityLabel("勾选发布 \(module.name)")
            }
            ModuleRow(
                module: module,
                combinedModuleEnabled: combinedModuleEnabled,
                onIncludedChange: { @MainActor included in
                    model.setModuleIncludedInCombined(id: module.id, included: included)
                }
            )
        }
        .tag(module.id)
        .contextMenu {
            Menu("编辑") {
                Button("视图编辑") { editModule(module) }
                    .help("在表单编辑器中修改模块来源、输出等设置")
                Button("文本编辑") { textEditModule(module) }
                    .help("直接编辑转换后的模块文本内容")
            }
            if module.storageLocation == .local {
                Button("在访达中显示") { revealModuleInFinder(module) }
            }
            Button("更新") { model.startUpdate(moduleID: module.id) }
            Button("复制模块") { try? model.duplicateModule(id: module.id) }
            Button("拷贝更新地址") { copyToPasteboard(module.updateSourceURL) }
            Button("拷贝输出路径") { copyToPasteboard(module.publishedRelativePath) }
            Divider()
            Menu("删除") {
                Button("仅从列表移除", role: .destructive) {
                    deleteCandidate = ModuleDeleteCandidate(module: module, mode: .removeFromList)
                }
                Button("删除并清理输出", role: .destructive) {
                    deleteCandidate = ModuleDeleteCandidate(module: module, mode: .clearOutput)
                }
                Button("彻底删除（含源文件）", role: .destructive) {
                    deleteCandidate = ModuleDeleteCandidate(module: module, mode: .deleteAll)
                }
            }
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func revealModuleInFinder(_ module: RelayModule) {
        let root = model.settings.localModuleDirectory
        guard !root.isEmpty else { return }
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let fileURL = rootURL.appendingPathComponent(module.publishedRelativePath)
        let folderURL = fileURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } else if FileManager.default.fileExists(atPath: folderURL.path) {
            // 输出文件尚未生成时，精确定位到其应处的文件夹
            NSWorkspace.shared.activateFileViewerSelecting([folderURL])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([rootURL])
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

    private var collapsedSectionIDs: Set<String> {
        Set(collapsedSectionIDsRaw.split(separator: ",").map(String.init))
    }

    private func isSectionExpanded(_ id: String) -> Bool {
        !collapsedSectionIDs.contains(id)
    }

    private func setSection(_ id: String, expanded: Bool) {
        var ids = collapsedSectionIDs
        if expanded {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        collapsedSectionIDsRaw = ids.sorted().joined(separator: ",")
    }
}

private struct ModuleSidebarSectionHeader: View {
    let title: String
    let count: Int
    let systemImage: String
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.22, extraBounce: 0.05)) {
                toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
                    .contentTransition(.symbolEffect(.replace))
                Label("\(title) \(count)", systemImage: systemImage)
                    .font(.caption.weight(.medium))
                    .labelStyle(.titleAndIcon)
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "收起\(title)" : "展开\(title)")
        .accessibilityLabel("\(isExpanded ? "收起" : "展开")\(title)")
    }
}

private struct ModuleSidebarStatusCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
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
                    .help("关闭错误提示")
                    .accessibilityLabel("关闭错误提示")
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
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
                            Text("\(model.synchronizationCompletedCount)/\(model.synchronizationTotalCount)")
                                .monospacedDigit()
                                .contentTransition(.numericText(value: Double(model.synchronizationCompletedCount)))
                                .animation(.smooth(duration: 0.25), value: model.synchronizationCompletedCount)
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
                            .contentTransition(.opacity)
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
                .transition(.opacity)
                Divider()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("最新更新时间")
                    .font(.caption.weight(.medium))
                Text(latestUpdateText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: statusCardShape)
        .overlay {
            statusCardShape
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.24), lineWidth: 0.5)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .animation(.snappy(duration: 0.22), value: model.workActivity.kind)
        .animation(.snappy(duration: 0.22), value: model.workActivity.isActive)
        .animation(.snappy(duration: 0.22), value: model.presentedError != nil)
        .animation(.snappy(duration: 0.22), value: model.automaticPublishRunsAt)
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

}

/// Pure value row: no AppModel observation in body reads, so bulk update progress
/// ticks only re-render rows whose module identity/content actually changed.
private struct ModuleRow: View {
    let module: RelayModule
    let combinedModuleEnabled: Bool
    let onIncludedChange: @MainActor (Bool) -> Void

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
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 4)
            ZStack {
                if module.state == .updating {
                    ProgressView()
                        .controlSize(.small)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                } else {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                        .help(statusHelp)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .frame(width: 14, height: 14)
            .accessibilityElement()
            .accessibilityLabel("状态：\(statusHelp)")
            if combinedModuleEnabled {
                Toggle("包含", isOn: Binding(
                    get: { module.isIncludedInCombined },
                    set: onIncludedChange
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
        }
        .padding(.vertical, 5)
        .opacity(combinedModuleEnabled && !module.isIncludedInCombined ? 0.55 : 1)
        .animation(.snappy(duration: 0.18), value: module.state)
        .animation(.snappy(duration: 0.18), value: module.isIncludedInCombined)
    }

    private var subtitle: String {
        if module.state == .failed, let failureSummary {
            return "更新失败：\(failureSummary)"
        }
        var parts = [module.displayStorageLocationTitle, module.initialSource.title]
        if !module.category.isEmpty { parts.append(module.category) }
        let folder = ModuleOutputFolder.normalized(module.outputFolder)
        if folder != ModuleOutputFolder.root {
            parts.append(ModuleOutputFolder.displayTitle(for: folder))
        }
        if !module.publishesStandalone { parts.append("不发布独立模块") }
        return parts.joined(separator: " · ")
    }

    private var failureSummary: String? {
        module.failureSummary
    }

    private var statusHelp: String {
        guard module.state == .failed, let failureSummary else { return module.state.title }
        return "\(module.state.title)：\(failureSummary)"
    }

    private var statusColor: Color {
        module.state.tintColor
    }
}

/// 待删除模块及其处理深度。
struct ModuleDeleteCandidate {
    let module: RelayModule
    let mode: ModuleDeletionMode
}
