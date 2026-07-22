import AppKit
import SwiftUI

struct ModuleSidebarView: View {
    @Environment(AppModel.self) private var model
    @SceneStorage("ModuleSidebarView.collapsedSectionIDs") private var collapsedSectionIDsRaw = ""
    let sections: [ModuleSidebarSection]
    let filteredModulesAreEmpty: Bool
    let allModulesAreEmpty: Bool
    let combinedModuleEnabled: Bool
    @Binding var isBatchSelecting: Bool
    @Binding var batchSelectedModuleIDs: Set<UUID>
    @Binding var deleteCandidate: RelayModule?
    let editModule: (RelayModule) -> Void

    var body: some View {
        @Bindable var model = model

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
                ContentUnavailableView(
                    allModulesAreEmpty ? "还没有模块" : "没有搜索结果",
                    systemImage: "shippingbox",
                    description: Text(allModulesAreEmpty ? "添加第一个更新地址，或扫描现有本地模块。" : "换个关键词试试。")
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ModuleSidebarStatusCard()
                .background(.bar)
        }
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
                    .disabled(!isGitHubPublishable(module))
                    .help(gitHubPublishHelp(for: module))
            }
            ModuleRow(
                module: module,
                combinedModuleEnabled: combinedModuleEnabled,
                onEnabledChange: { enabled in
                    model.setModuleEnabled(id: module.id, enabled: enabled)
                }
            )
        }
        .tag(module.id)
        .contextMenu {
            Button("编辑") { editModule(module) }
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

    private func isGitHubPublishable(_ module: RelayModule) -> Bool {
        module.publishesStandalone && module.storageLocation == .gitHub
    }

    private func gitHubPublishHelp(for module: RelayModule) -> String {
        if !module.publishesStandalone { return "该模块未开启独立发布" }
        if module.storageLocation != .gitHub { return "本地模块不会发布为 GitHub 独立模块" }
        return "选择发布该 GitHub 模块"
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

    private var synchronizationPercentage: Int {
        Int((synchronizationProgress * 100).rounded())
    }
}

/// Pure value row: no AppModel observation in body reads, so bulk update progress
/// ticks only re-render rows whose module identity/content actually changed.
private struct ModuleRow: View {
    let module: RelayModule
    let combinedModuleEnabled: Bool
    let onEnabledChange: (Bool) -> Void

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
            if combinedModuleEnabled {
                Toggle("包含", isOn: Binding(
                    get: { module.isEnabled },
                    set: onEnabledChange
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
        }
        .padding(.vertical, 5)
        .opacity(combinedModuleEnabled && !module.isEnabled ? 0.55 : 1)
        .animation(.snappy(duration: 0.18), value: module.state)
        .animation(.snappy(duration: 0.18), value: module.isEnabled)
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
