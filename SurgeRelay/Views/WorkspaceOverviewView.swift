import SwiftUI

struct WorkspaceOverviewView: View {
    @Environment(AppModel.self) private var model
    let addModule: () -> Void
    let scanLocalModules: () -> Void
    let filterModules: (ModuleFilter) -> Void

    private var summary: ModuleCollectionSummary { model.moduleSummary }
    private var attention: [RelayModule] {
        Array(model.modules.lazy.filter {
            ModuleFilter.attention.matches($0, combinedModuleEnabled: model.settings.combinedModuleEnabled)
        }.prefix(3))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                metrics
                if model.modules.isEmpty { onboarding }
                else { attentionSection }
                destinations
                recentActivity
            }
            .frame(maxWidth: 940, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Design.Palette.canvas)
        .accessibilityIdentifier("workspace.overview")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("SURGE RELAY")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(2.2)
                    .foregroundStyle(Design.Palette.accent)
                Spacer()
                Label(model.workActivity.isActive ? model.workActivity.title : "本机工作空间",
                      systemImage: model.workActivity.isActive ? "arrow.triangle.2.circlepath" : "desktopcomputer")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("模块工作台")
                        .font(.system(size: 32, weight: .bold))
                    Text("从来源更新到稳定发布，每一步都在这里。")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(action: addModule) {
                    Label("添加模块", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("workspace.add")
            }
        }
    }

    private var metrics: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                metric("模块总数", count: summary.totalCount, filter: .all)
                Divider().padding(.vertical, 22)
                metric("可更新", count: summary.updateableCount, filter: .updatable)
                Divider().padding(.vertical, 22)
                metric("独立发布", count: summary.standaloneCount, filter: .standalone)
                Divider().padding(.vertical, 22)
                metric("需要处理", count: summary.attentionCount, filter: .attention)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 0), GridItem(.flexible())], spacing: 0) {
                metric("模块总数", count: summary.totalCount, filter: .all)
                metric("可更新", count: summary.updateableCount, filter: .updatable)
                metric("独立发布", count: summary.standaloneCount, filter: .standalone)
                metric("需要处理", count: summary.attentionCount, filter: .attention)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .detailCard(radius: Design.Radius.large)
    }

    private func metric(_ title: String, count: Int, filter: ModuleFilter) -> some View {
        Button { filterModules(filter) } label: {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
                Text(count, format: .number)
                    .font(.system(size: 31, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(filter == .attention && count > 0 ? Design.Palette.warning : Color.primary)
            }
            .frame(minWidth: 110, maxWidth: .infinity, alignment: .leading)
            .padding(22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("在模块库中查看\(title)")
        .accessibilityLabel("\(title)：\(count)，查看模块")
        .accessibilityIdentifier("workspace.metric.\(filter.rawValue)")
    }

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("把第一个模块交给 Relay", systemImage: "square.stack.3d.up")
                .font(.title3.weight(.semibold))
            Text("粘贴 Surge、Loon 或 Quantumult X 来源地址，或导入已有的本地模块。Relay 会维护转换结果与发布地址。")
                .font(.system(size: 14)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("添加来源", systemImage: "link", action: addModule)
                    .buttonStyle(.borderedProminent)
                Button("扫描本地模块", systemImage: "folder.badge.plus", action: scanLocalModules)
                    .buttonStyle(.bordered)
                    .disabled(model.isWorking)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .detailCard(radius: Design.Radius.large)
    }

    private var attentionSection: some View {
        let visibleAttention = attention
        let lastAttentionID = visibleAttention.last?.id
        return VStack(alignment: .leading, spacing: 14) {
            WorkspaceSectionHeader(title: "运行状态", actionTitle: visibleAttention.isEmpty ? nil : "查看全部 \(summary.attentionCount) 项") {
                filterModules(.attention)
            }
            VStack(alignment: .leading, spacing: 0) {
                if visibleAttention.isEmpty {
                    HStack(spacing: 14) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 28)).foregroundStyle(Design.Palette.success)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("没有需要处理的问题").font(.system(size: 15, weight: .semibold))
                            Text("更新失败和内容冲突会集中显示在这里。")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("检查更新") { model.startUpdateAll() }
                            .buttonStyle(.bordered)
                            .disabled(!model.updateAdmission.isAccepted)
                            .help(model.updateAdmission.message)
                            .fixedSize()
                    }.padding(20)
                } else {
                    ForEach(visibleAttention) { module in
                        Button { model.selectedModuleID = module.id } label: {
                            HStack(spacing: 12) {
                                ModuleIconView(module: module, size: 32)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(module.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                        .help(module.name)
                                    Text(attentionMessage(for: module))
                                        .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
                                        .help(attentionMessage(for: module))
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }.padding(18).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .accessibilityLabel("\(module.name)，\(attentionMessage(for: module))")
                        .accessibilityHint("查看模块详情")
                        if module.id != lastAttentionID { Divider().padding(.leading, 62) }
                    }
                }
            }.detailCard()
        }
    }

    private var destinations: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkspaceSectionHeader(title: "发布去向", actionTitle: "管理发布") { openPublishingSettings() }
            LazyVGrid(columns: [GridItem(.flexible(minimum: 210), spacing: 16), GridItem(.flexible(minimum: 210))], spacing: 16) {
                WorkspaceDestinationCard(
                    title: "本地目录", symbol: "externaldrive",
                    enabled: model.settings.publishToLocal,
                    configured: !model.settings.localModuleDirectory.isEmpty,
                    detail: model.settings.localModuleDirectory.isEmpty ? "选择 Surge 模块目录" : model.settings.localModuleDirectory,
                    caption: "\(model.modules.lazy.filter(\.hasLocalStorageTarget).count) 个模块存放在本地",
                    action: openPublishingSettings
                )
                WorkspaceDestinationCard(
                    title: "GitHub", symbol: "cloud",
                    enabled: model.settings.publishToGitHub,
                    configured: model.settings.github.isConfigured,
                    detail: model.settings.github.isConfigured
                        ? "\(model.settings.github.owner)/\(model.settings.github.repository)" : "连接仓库以分发模块",
                    caption: model.settings.publishToGitHub
                        ? "\(model.modules.lazy.filter(\.hasGitHubStorageTarget).count) 个模块 · \(model.settings.github.branch)" : "开启后可自动发布更新",
                    action: openPublishingSettings
                )
            }
        }
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkspaceSectionHeader(title: "最近活动", actionTitle: "全部记录") { model.selectedModuleID = AppModel.activitySelectionID }
            if model.updateHistory.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "clock").foregroundStyle(.secondary)
                    Text("更新和发布后，操作记录会出现在这里。")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                    Spacer()
                }.padding(20).detailCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.updateHistory.prefix(4))) { entry in
                        ActivityHistoryRow(entry: entry)
                        if entry.id != model.updateHistory.prefix(4).last?.id { Divider().padding(.leading, 58) }
                    }
                }.detailCard()
            }
        }
    }

    private func openPublishingSettings() {
        model.settingsPage = .publishing
        model.presentsSettings = true
    }

    private func attentionMessage(for module: RelayModule) -> String {
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
        HStack {
            Text(title).font(.system(size: 15, weight: .semibold))
            Spacer()
            if let actionTitle {
                Button(actionTitle, action: action).buttonStyle(.borderless).font(.system(size: 13))
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
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Image(systemName: symbol).font(.title3).foregroundStyle(Design.Palette.accent)
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Label(statusTitle, systemImage: enabled ? (configured ? "checkmark.circle.fill" : "exclamationmark.circle") : "circle")
                        .font(.system(size: 12)).foregroundStyle(statusColor).fixedSize()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(detail).font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(caption).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(20).frame(maxWidth: .infinity, minHeight: 126, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).detailCard()
        .help(detail)
        .accessibilityLabel("\(title)，\(statusTitle)")
        .accessibilityValue(detail)
        .accessibilityHint("打开发布设置")
    }
}
