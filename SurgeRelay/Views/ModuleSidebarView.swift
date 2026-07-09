import AppKit
import SwiftUI

struct ModuleSidebarView: View {
    @Environment(AppModel.self) private var model
    @SceneStorage("ModuleSidebarView.collapsedSectionIDs") private var collapsedSectionIDsRaw = ""
    let sections: [ModuleSidebarSection]
    let filteredModulesAreEmpty: Bool
    let allModulesAreEmpty: Bool
    @Binding var isBatchSelecting: Bool
    @Binding var batchSelectedModuleIDs: Set<UUID>
    @Binding var deleteCandidate: RelayModule?
    let editModule: (RelayModule) -> Void

    var body: some View {
        @Bindable var model = model

        List(selection: $model.selectedModuleID) {
            if model.settings.combinedModuleEnabled {
                Section {
                    CombinedModuleRow()
                        .tag(AppModel.combinedModuleSelectionID)
                }
            }

            ForEach(sections) { section in
                moduleSection(section)
            }
        }
        .overlay {
            if filteredModulesAreEmpty {
                ContentUnavailableView(
                    allModulesAreEmpty ? "还没有模块" : "没有搜索结果",
                    systemImage: "shippingbox",
                    description: Text(allModulesAreEmpty ? "添加第一个原始地址，Surge Relay 会生成模块输出。" : "换个关键词试试。")
                )
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
                    .disabled(!module.publishesStandalone)
                    .help(module.publishesStandalone ? "选择发布该模块" : "该模块未开启独立发布")
            }
            ModuleRow(module: module)
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
            withAnimation(.snappy) {
                toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
                Label("\(title) \(count)", systemImage: systemImage)
                    .font(.caption.weight(.medium))
                    .labelStyle(.titleAndIcon)
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
        var parts = [module.displayStorageLocationTitle, module.sourceOrigin.title]
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
