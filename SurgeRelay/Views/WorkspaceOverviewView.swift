import SwiftUI

struct WorkspaceOverviewView: View {
    @Environment(AppModel.self) private var model
    let addModule: () -> Void
    let scanLocalModules: () -> Void
    let filterModules: (ModuleFilter) -> Void

    private var summary: ModuleCollectionSummary { model.moduleSummary }
    private var attention: [RelayModule] {
        Array(model.modules.lazy.filter {
            ModuleFilter.attention.matches($0)
        }.prefix(4))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                metrics
                if model.modules.isEmpty {
                    onboarding
                } else {
                    attentionSection
                }
                destinations
                recentActivity
            }
            .frame(maxWidth: 960, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Design.Palette.canvas)
        .accessibilityIdentifier("workspace.overview")
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                headerTitleBlock
                Spacer(minLength: 12)
                headerActionButtons
            }
            VStack(alignment: .leading, spacing: 12) {
                headerTitleBlock
                headerActionButtons
            }
        }
    }

    private var headerTitleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("模块工作台")
                    .font(.system(size: 22, weight: .bold))
                MetadataPill(
                    model.workspaceName,
                    systemImage: "square.stack.3d.up"
                )
                if model.workActivity.isActive {
                    MetadataPill(
                        model.workActivity.title,
                        systemImage: "arrow.triangle.2.circlepath",
                        tint: Design.Palette.accent
                    )
                }
            }
            Text("集中管理多客户端模块转换、本地目录同步与 GitHub 稳定分发。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var headerActionButtons: some View {
        HStack(spacing: 8) {
            Button {
                model.startUpdateAll()
            } label: {
                Label("更新全部", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(!model.updateAdmission.isAccepted)
            .help(model.updateAdmission.isAccepted ? "更新全部可更新模块" : model.updateAdmission.message)

            Button(action: scanLocalModules) {
                Label("扫描本地", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.bordered)
            .disabled(model.isWorking)

            Button(action: addModule) {
                Label("添加模块", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("workspace.add")
        }
        .controlSize(.regular)
    }

    private var metrics: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                metricTile("模块总数", symbol: "square.stack.3d.up.fill", tint: Design.Palette.accent, count: summary.totalCount, filter: .all)
                metricTile("可更新", symbol: "arrow.triangle.2.circlepath", tint: Design.Palette.success, count: summary.updateableCount, filter: .updatable)
                metricTile("本地模块", symbol: "externaldrive.fill", tint: .secondary, count: summary.localCount, filter: .local)
                metricTile("需要处理", symbol: "exclamationmark.triangle.fill", tint: summary.attentionCount > 0 ? Design.Palette.warning : .secondary, count: summary.attentionCount, filter: .attention)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                metricTile("模块总数", symbol: "square.stack.3d.up.fill", tint: Design.Palette.accent, count: summary.totalCount, filter: .all)
                metricTile("可更新", symbol: "arrow.triangle.2.circlepath", tint: Design.Palette.success, count: summary.updateableCount, filter: .updatable)
                metricTile("本地模块", symbol: "externaldrive.fill", tint: .secondary, count: summary.localCount, filter: .local)
                metricTile("需要处理", symbol: "exclamationmark.triangle.fill", tint: summary.attentionCount > 0 ? Design.Palette.warning : .secondary, count: summary.attentionCount, filter: .attention)
            }
        }
    }

    private func metricTile(
        _ title: String,
        symbol: String,
        tint: Color,
        count: Int,
        filter: ModuleFilter
    ) -> some View {
        Button { filterModules(filter) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 22, height: 22)
                        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.quaternary)
                }
                Text(count, format: .number)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(filter == .attention && count > 0 ? Design.Palette.warning : Color.primary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .detailCard()
        }
        .buttonStyle(.plain)
        .help("在模块库中筛选：\(title)")
        .accessibilityLabel("\(title)：\(count)，查看模块")
        .accessibilityIdentifier("workspace.metric.\(filter.rawValue)")
    }

    private var onboarding: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(systemName: "square.stack.3d.up.badge.automatic")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Design.Palette.accent)
                .frame(width: 54, height: 54)
                .background(Design.Palette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text("开始管理第一个模块")
                    .font(.system(size: 15, weight: .semibold))
                Text("添加 Surge、Loon、Quantumult X 远程地址，或直接扫描现有本地模块目录纳入同步管理。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("添加远程或本地来源", systemImage: "plus", action: addModule)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("扫描本地模块目录", systemImage: "folder.badge.plus", action: scanLocalModules)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.isWorking)
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .detailCard(radius: Design.Radius.large)
    }

    private var attentionSection: some View {
        let visibleAttention = attention
        return VStack(alignment: .leading, spacing: 8) {
            WorkspaceSectionHeader(
                title: "运行状态",
                actionTitle: visibleAttention.isEmpty ? nil : "查看全部 \(summary.attentionCount) 项"
            ) {
                filterModules(.attention)
            }

            if visibleAttention.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Design.Palette.success)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("没有需要处理的问题")
                            .font(.system(size: 13, weight: .semibold))
                        Text("所有模块缓存与输出状态正常；更新失败或内容冲突会在此提示。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("检查更新") { model.startUpdateAll() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!model.updateAdmission.isAccepted)
                        .help(model.updateAdmission.message)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .detailCard()
            } else {
                GroupedCardStack(dividerInset: 42) {
                    ForEach(visibleAttention) { module in
                        HStack(spacing: 10) {
                            Button { model.selectedModuleID = module.id } label: {
                                HStack(spacing: 10) {
                                    ModuleIconView(module: module, size: 30)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(module.name)
                                                .font(.system(size: 13, weight: .semibold))
                                                .lineLimit(1)
                                            MetadataPill(
                                                attentionBadge(for: module),
                                                tint: module.state == .failed || module.localOutputError != nil ? Design.Palette.error : Design.Palette.warning
                                            )
                                        }
                                        Text(attentionMessage(for: module))
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(module.name)，\(attentionMessage(for: module))")
                            .accessibilityHint("查看模块详情")

                            if module.state == .failed, model.updateAdmission(for: module).isAccepted {
                                Button("重试") {
                                    model.startUpdate(moduleID: module.id)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            Button {
                                model.selectedModuleID = module.id
                            } label: {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 10)
                    }
                }
            }
        }
    }

    private var destinations: some View {
        VStack(alignment: .leading, spacing: 8) {
            WorkspaceSectionHeader(title: "发布去向", actionTitle: "发布设置…") { openPublishingSettings() }
            LazyVGrid(columns: [GridItem(.flexible(minimum: 220), spacing: 12), GridItem(.flexible(minimum: 220), spacing: 12)], spacing: 12) {
                WorkspaceDestinationCard(
                    title: "本地目录",
                    symbol: "externaldrive",
                    enabled: model.settings.publishToLocal,
                    configured: localStorageFormats.contains { !model.settings.localModuleDirectory(for: $0).isEmpty },
                    detail: localStorageFormats.isEmpty ? "尚未启用客户端本地目录" : localStorageFormats.map(\.title).joined(separator: " · "),
                    caption: "\(localStorageFormats.count) 个客户端已启用 · \(model.modules.lazy.filter(\.hasLocalStorageTarget).count) 个本地模块",
                    action: openPublishingSettings
                )
                WorkspaceDestinationCard(
                    title: "GitHub 分发",
                    symbol: "cloud",
                    enabled: model.settings.publishToGitHub,
                    configured: model.settings.github.isConfigured,
                    detail: model.settings.github.isConfigured
                        ? "\(model.settings.github.owner)/\(model.settings.github.repository)" : "尚未连接 GitHub 仓库",
                    caption: model.settings.publishToGitHub
                        ? "\(model.modules.lazy.filter(\.hasGitHubStorageTarget).count) 个模块 · 分支 \(model.settings.github.branch)" : "连接仓库以生成固定订阅地址",
                    action: openPublishingSettings
                )
            }
        }
    }

    private var localStorageFormats: [ModuleOutputFormat] {
        ModuleOutputFormat.allCases.filter { model.settings.isLocalPublishingEnabled(for: $0) }
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 8) {
            WorkspaceSectionHeader(title: "最近活动", actionTitle: "全部记录") {
                model.selectedModuleID = AppModel.activitySelectionID
            }
            if model.updateHistory.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "clock")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                    Text("执行模块更新或发布后，最近的操作记录会显示在这里。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .detailCard()
            } else {
                GroupedCardStack(dividerInset: 40, horizontalPadding: 0, verticalPadding: 2) {
                    ForEach(Array(model.updateHistory.prefix(5))) { entry in
                        ActivityHistoryRow(entry: entry)
                    }
                }
            }
        }
    }

    private func openPublishingSettings() {
        model.settingsPage = .publishing
        model.presentsSettings = true
    }

    private func attentionBadge(for module: RelayModule) -> String {
        if module.localOutputError != nil { return "本地异常" }
        if module.state == .failed { return "更新失败" }
        if module.hasSyncConflict { return "同步冲突" }
        return "编辑冲突"
    }

    private func attentionMessage(for module: RelayModule) -> String {
        if let error = module.localOutputError { return error.components(separatedBy: .newlines).first ?? error }
        if module.state == .failed { return module.failureSummary ?? "更新失败，请查看错误详情" }
        if module.hasSyncConflict { return "本地发布文件与 GitHub 内容不同，需要选择保留的版本" }
        return "上游内容已变化，需要检查本地编辑"
    }
}

struct WorkspaceSectionHeader: View {
    let title: String
    var actionTitle: String?
    var action: () -> Void = {}

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            Spacer()
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .medium))
            }
        }
    }
}

private struct WorkspaceDestinationCard: View {
    let title: String
    let symbol: String
    let enabled: Bool
    let configured: Bool
    let detail: String
    let caption: String
    let action: () -> Void

    private var statusTitle: String { enabled ? (configured ? "已开启" : "待配置") : "未开启" }
    private var statusColor: Color { enabled ? (configured ? Design.Palette.success : Design.Palette.warning) : .secondary }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(enabled ? Design.Palette.accent : Design.Palette.icon)
                        .frame(width: 26, height: 26)
                        .background((enabled ? Design.Palette.accent : Color.primary).opacity(0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    MetadataPill(
                        statusTitle,
                        systemImage: enabled ? (configured ? "checkmark.circle.fill" : "exclamationmark.circle") : "minus.circle",
                        tint: enabled ? statusColor : nil
                    )
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(detail)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .detailCard()
        }
        .buttonStyle(.plain)
        .help(detail)
        .accessibilityLabel("\(title)，\(statusTitle)")
        .accessibilityValue(detail)
        .accessibilityHint("打开发布设置")
    }
}
