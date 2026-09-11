import AppKit
import SwiftUI

@MainActor
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
    let addModule: () -> Void

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Button { model.selectedModuleID = AppModel.overviewSelectionID } label: {
                    Label("工作台", systemImage: "square.grid.2x2")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .contentShape(Rectangle())
                        .background(model.selectedModuleID == AppModel.overviewSelectionID ? Design.Palette.accent.opacity(0.12) : .clear,
                                    in: .rect(cornerRadius: 6))
                }
                .accessibilityAddTraits(model.selectedModuleID == AppModel.overviewSelectionID ? .isSelected : [])
                .accessibilityIdentifier("navigation.overview")
                Button { model.selectedModuleID = AppModel.activitySelectionID } label: {
                    Label("活动记录", systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .contentShape(Rectangle())
                        .background(model.selectedModuleID == AppModel.activitySelectionID ? Design.Palette.accent.opacity(0.12) : .clear,
                                    in: .rect(cornerRadius: 6))
                }
                .accessibilityAddTraits(model.selectedModuleID == AppModel.activitySelectionID ? .isSelected : [])
                .accessibilityIdentifier("navigation.activity")
            }
            .font(.system(size: 14, weight: .medium))
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.top, 8)

            ModuleSidebarFilterBar(selection: $sidebarFilter, sortOrder: $sortOrder,
                                   searchText: $searchText,
                                   counts: filterCounts, resultCount: resultCount)
                .padding(.horizontal, 14)
                .padding(.top, 8)

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
                if filteredModulesAreEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(emptyStateTitle).font(.system(size: 14, weight: .semibold))
                        Text(emptyStateDescription).font(.system(size: 13)).foregroundStyle(.secondary)
                        if allModulesAreEmpty {
                            Button("添加模块", systemImage: "plus", action: addModule)
                        } else {
                            Button("清除筛选与搜索") { sidebarFilter = .all; searchText = "" }
                        }
                    }.padding(.vertical, 20).listRowSeparator(.hidden)
                }
            }
            .listStyle(.sidebar)
            .animation(.snappy(duration: 0.2), value: sections.map(\.id))
            .animation(.snappy(duration: 0.2), value: collapsedSectionIDsRaw)
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
        if sidebarFilter != .all { return "可点击“重置”清除筛选与搜索，或切换“全部”筛选。" }
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
                isSelected: model.selectedModuleID == module.id,
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
                .disabled(!model.updateAdmission(for: module).isAccepted)
                .help(model.updateAdmission(for: module).message)
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

@MainActor
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
        .accessibilityValue("\(count) 个模块，\(isExpanded ? "已展开" : "已收起")")
    }
}

/// Pure value row: no AppModel observation in body reads, so bulk update progress
/// ticks only re-render rows whose module identity/content actually changed.
private struct ModuleRow: View {
    let module: RelayModule
    let isSelected: Bool
    let combinedModuleEnabled: Bool
    let onIncludedChange: @MainActor (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ModuleIconView(module: module, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(module.name)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .help(module.name)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .help(subtitle)
            }
            Spacer(minLength: 4)
            ZStack {
                if module.state == .updating {
                    ProgressView()
                        .controlSize(.small)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                } else {
                    Image(systemName: module.state.systemImage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isSelected ? Color.primary : statusColor)
                        .frame(width: 14, height: 14)
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
                .help("将 \(module.name) 包含在总模块中")
                .accessibilityLabel("\(module.name) 参与总模块")
            }
        }
        .padding(.vertical, 7)
        .animation(.snappy(duration: 0.18), value: module.state)
        .animation(.snappy(duration: 0.18), value: module.isIncludedInCombined)
    }

    private var subtitle: String {
        if module.state == .failed, let failureSummary {
            return "更新失败：\(failureSummary)"
        }
        var parts = [module.initialSource.title]
        if !module.category.isEmpty { parts.append(module.category) }
        let folder = ModuleOutputFolder.normalized(module.outputFolder)
        if folder != ModuleOutputFolder.root {
            parts.append(ModuleOutputFolder.displayTitle(for: folder))
        }
        return parts.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: " · ")
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
