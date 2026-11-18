import AppKit
import SwiftUI

@MainActor
struct ModuleSidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkspaceController.self) private var workspaces: WorkspaceController?
    @SceneStorage("ModuleSidebarView.collapsedSectionIDs") private var collapsedSectionIDsRaw = ""
    let sections: [ModuleSidebarSection]
    let filteredModulesAreEmpty: Bool
    let allModulesAreEmpty: Bool
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
    let isScanningLocalModules: Bool
    let scanLocalModules: () -> Void

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            VStack(spacing: 8) {
                searchField
                ModuleSidebarToolbarContent(
                    isBatchSelecting: $isBatchSelecting,
                    batchSelectedModuleIDs: $batchSelectedModuleIDs,
                    isScanningLocalModules: isScanningLocalModules,
                    addModule: addModule,
                    scanLocalModules: scanLocalModules
                )
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)

            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)

            List(selection: $model.selectedModuleID) {
                workspaceNavigation
                    .listRowInsets(EdgeInsets(top: 6, leading: 2, bottom: 4, trailing: 2))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .selectionDisabled()

                ModuleSidebarFilterBar(
                    selection: $sidebarFilter,
                    sortOrder: $sortOrder,
                    searchText: $searchText,
                    counts: filterCounts,
                    resultCount: resultCount
                )
                .padding(.horizontal, 4)
                .listRowInsets(EdgeInsets(top: 6, leading: 2, bottom: 2, trailing: 2))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .selectionDisabled()

                ForEach(sections) { section in
                    moduleSection(section)
                }

                if filteredModulesAreEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(emptyStateTitle)
                            .font(.system(size: 13, weight: .semibold))
                        Text(emptyStateDescription)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        if allModulesAreEmpty {
                            Button("添加模块", systemImage: "plus", action: addModule)
                                .controlSize(.small)
                        } else {
                            Button("清除筛选与搜索") {
                                sidebarFilter = .all
                                searchText = ""
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 16)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.sidebar)
            .frame(minHeight: 100)
            .accessibilityIdentifier("modules.list")
            .animation(.snappy(duration: 0.2), value: sections.map(\.id))
            .animation(.snappy(duration: 0.2), value: collapsedSectionIDsRaw)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ModuleSidebarStatusCard()
        }
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("modules.sidebar")
    }

    private var workspaceNavigation: some View {
        VStack(alignment: .leading, spacing: 6) {
            workspaceSwitcherHeader
                .padding(.horizontal, 6)

            VStack(spacing: 2) {
                sidebarNavButton(
                    title: "工作台",
                    systemImage: "square.grid.2x2",
                    targetID: AppModel.overviewSelectionID,
                    badge: model.moduleSummary.attentionCount > 0 ? "\(model.moduleSummary.attentionCount)" : nil,
                    badgeIsWarning: true,
                    identifier: "navigation.overview"
                )
                sidebarNavButton(
                    title: "活动记录",
                    systemImage: "clock.arrow.circlepath",
                    targetID: AppModel.activitySelectionID,
                    badge: !model.pendingModuleSaves.isEmpty ? "\(model.pendingModuleSaves.count)" : nil,
                    badgeIsWarning: model.pendingModuleSaves.contains { $0.errorMessage != nil },
                    identifier: "navigation.activity"
                )
                sidebarNavButton(
                    title: "转换工具",
                    systemImage: "arrow.left.arrow.right.square",
                    targetID: AppModel.conversionToolsSelectionID,
                    badge: nil,
                    badgeIsWarning: false,
                    identifier: "navigation.tools"
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var workspaceSwitcherHeader: some View {
        if let workspaces, workspaces.registry.workspaces.count > 1 {
            Menu {
                Section("切换工作区") {
                    ForEach(workspaces.registry.workspaces) { workspace in
                        Button {
                            guard workspace.id != model.workspaceID else { return }
                            Task { try? await workspaces.switchWorkspace(to: workspace.id) }
                        } label: {
                            Label(workspace.name, systemImage: workspace.id == model.workspaceID ? "checkmark" : "square.stack.3d.up")
                        }
                    }
                }
                Divider()
                Button("管理工作区…") {
                    model.settingsPage = .workspaces
                    model.presentsSettings = true
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 10, weight: .semibold))
                    Text(model.workspaceName)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("当前工作区：\(model.workspaceName)（点击切换）")
            .accessibilityIdentifier("workspace.current")
        } else {
            Button {
                model.settingsPage = .workspaces
                model.presentsSettings = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 10, weight: .semibold))
                    Text(model.workspaceName)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("当前工作区：\(model.workspaceName)")
            .accessibilityIdentifier("workspace.current")
        }
    }

    private func sidebarNavButton(
        title: String,
        systemImage: String,
        targetID: UUID,
        badge: String?,
        badgeIsWarning: Bool,
        identifier: String
    ) -> some View {
        let isSelected = model.selectedModuleID == targetID
        return Button {
            model.selectedModuleID = targetID
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Design.Palette.accent : .secondary)
                    .frame(width: 18, alignment: .center)
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Design.Palette.accent : .primary)
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(badgeIsWarning ? Design.Palette.warning : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            (badgeIsWarning ? Design.Palette.warning : Color.primary).opacity(0.12),
                            in: Capsule()
                        )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                isSelected ? Design.Palette.accent.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("搜索模块", text: $searchText)
                .font(.system(size: 12))
                .textFieldStyle(.plain)
                .onExitCommand { searchText = "" }
                .accessibilityLabel("搜索模块")
                .accessibilityIdentifier("modules.search")
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除模块搜索（Esc）")
                .accessibilityLabel("清除模块搜索")
                .accessibilityIdentifier("modules.clear-search")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
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
        HStack(spacing: 6) {
            if isBatchSelecting {
                Toggle("", isOn: batchSelectionBinding(for: module.id))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .help("勾选后随“发布所选”发布到该模块的存放位置")
                    .accessibilityLabel("勾选发布 \(module.name)")
            }
            ModuleRow(
                module: module,
                isSelected: model.selectedModuleID == module.id
            )
        }
        .tag(module.id)
        .accessibilityIdentifier("modules.row.\(module.id.uuidString)")
        .contextMenu {
            ModuleSidebarContextMenu(
                moduleID: module.id,
                model: model,
                deleteCandidate: $deleteCandidate,
                editModule: editModule,
                textEditModule: textEditModule
            )
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
private struct ModuleSidebarContextMenu: View {
    let moduleID: UUID
    let model: AppModel
    @Binding var deleteCandidate: ModuleDeleteCandidate?
    let editModule: (RelayModule) -> Void
    let textEditModule: (RelayModule) -> Void

    var body: some View {
        if let module = model.modules.first(where: { $0.id == moduleID }) {
            let admission = model.updateAdmission(for: module)
            Button("编辑配置…") { editModule(module) }
            Button("编辑模块内容…") { textEditModule(module) }
            Divider()
            Button("立即更新") { model.startUpdate(moduleID: module.id) }
                .disabled(!admission.isAccepted)
                .help(admission.message)
            if module.hasLocalStorageTarget {
                Button("在访达中显示") { revealModuleInFinder(module) }
            }
            Button("复制模块副本") { try? model.duplicateModule(id: module.id) }
            Divider()
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
        let root = model.settings.localModuleDirectory(for: module.outputFormat)
        guard !root.isEmpty else { return }
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let fileURL = rootURL.appendingPathComponent(module.publishedRelativePath)
        let folderURL = fileURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } else if FileManager.default.fileExists(atPath: folderURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([folderURL])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([rootURL])
        }
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
            withAnimation(.snappy(duration: 0.2, extraBounce: 0.03)) {
                toggle()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
                    .contentTransition(.symbolEffect(.replace))
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "收起\(title)" : "展开\(title)")
        .accessibilityLabel("\(isExpanded ? "收起" : "展开")\(title)")
        .accessibilityValue("\(count) 个模块，\(isExpanded ? "已展开" : "已收起")")
    }
}

private struct ModuleRow: View {
    let module: RelayModule
    let isSelected: Bool

    private var hasIssue: Bool {
        module.localOutputError != nil || module.state == .failed || module.hasOverrideConflict || module.hasSyncConflict
    }

    var body: some View {
        HStack(spacing: 9) {
            ModuleIconView(module: module, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(module.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .help(module.name)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(hasIssue && !isSelected ? Design.Palette.warning : .secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .help(subtitle)
            }
            Spacer(minLength: 4)
            ZStack {
                if module.state == .updating {
                    ProgressView()
                        .controlSize(.mini)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                } else if hasIssue {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.primary : (module.state == .failed || module.localOutputError != nil ? Design.Palette.error : Design.Palette.warning))
                        .frame(width: 14, height: 14)
                        .help(statusHelp)
                } else if module.state == .current {
                    Circle()
                        .fill(isSelected ? Color.primary.opacity(0.7) : Design.Palette.success)
                        .frame(width: 6, height: 6)
                        .help(statusHelp)
                } else {
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1.2)
                        .frame(width: 6, height: 6)
                        .help(statusHelp)
                }
            }
            .frame(width: 14, height: 14)
            .accessibilityElement()
            .accessibilityLabel("状态：\(statusHelp)")
        }
        .padding(.vertical, 4)
        .animation(.snappy(duration: 0.18), value: module.state)
    }

    private var subtitle: String {
        if module.localOutputError != nil {
            return "本地输出异常 · " + module.publishedRelativePath
        }
        if module.state == .failed, let failureSummary {
            return failureSummary
        }
        if module.hasSyncConflict {
            return "两端同步冲突 · " + module.outputFormat.title
        }
        if module.hasOverrideConflict {
            return "上游已更新 · 保留本地编辑"
        }
        var parts = [module.outputFormat.title, module.initialSource.title]
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
        if let error = module.localOutputError { return "本地输出失败：" + error }
        guard module.state == .failed, let failureSummary else { return module.state.title }
        return "\(module.state.title)：\(failureSummary)"
    }
}

struct ModuleDeleteCandidate {
    let module: RelayModule
    let mode: ModuleDeletionMode
}
