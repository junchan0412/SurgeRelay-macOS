import SwiftUI

struct ModuleSidebarToolbarContent: View {
    @Environment(AppModel.self) private var model
    @Binding var isBatchSelecting: Bool
    @Binding var batchSelectedModuleIDs: Set<UUID>
    let isScanningLocalModules: Bool
    let addModule: () -> Void
    let scanLocalModules: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                addModuleButton
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    updateAllButton
                    publishAllButton
                    moreActionsMenu
                }
            }

            if isBatchSelecting {
                HStack(spacing: 8) {
                    Text("已选 \(batchSelectedModuleIDs.count) 个")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("modules.selected-count")
                    Spacer(minLength: 0)
                    Button("取消") {
                        isBatchSelecting = false
                        batchSelectedModuleIDs.removeAll()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                    publishSelectedButton
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Design.Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("modules.actions")
    }

    private var addModuleButton: some View {
        Button(action: addModule) {
            Label("添加", systemImage: "plus")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("n", modifiers: .command)
        .help("添加模块（⌘N）")
        .accessibilityLabel("添加模块")
        .accessibilityIdentifier("modules.add")
    }

    private var updateAllButton: some View {
        Button {
            model.startUpdateAll()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 24)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("r", modifiers: .command)
        .disabled(!model.updateAdmission.isAccepted)
        .opacity(model.updateAdmission.isAccepted ? 1 : 0.4)
        .help(model.updateAdmission.isAccepted ? "更新全部模块（⌘R）" : model.updateAdmission.message)
        .accessibilityLabel("更新全部")
        .accessibilityIdentifier("modules.update-all")
    }

    private var publishAllButton: some View {
        Button {
            publishAllAction()
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 24)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("p", modifiers: [.command, .shift])
        .disabled(model.isWorking)
        .opacity(model.isWorking ? 0.4 : 1)
        .help(publishAllHelp)
        .accessibilityLabel("发布到 GitHub")
        .accessibilityIdentifier("modules.publish-all")
    }

    private var moreActionsMenu: some View {
        Menu {
            Group {
                batchSelectionButton
                if isBatchSelecting {
                    selectAllButton
                    clearSelectionButton
                }
                Divider()
                scanLocalModulesButton
            }
            .labelStyle(.titleAndIcon)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 24)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多操作")
        .accessibilityLabel("更多模块操作")
        .accessibilityIdentifier("modules.more-actions")
    }

    private var batchSelectionButton: some View {
        Button {
            isBatchSelecting.toggle()
            if !isBatchSelecting { batchSelectedModuleIDs.removeAll() }
        } label: {
            Label(isBatchSelecting ? "结束选择" : "批量选择发布", systemImage: isBatchSelecting ? "checkmark.circle" : "checklist")
        }
        .disabled(model.isWorking)
        .help(isBatchSelecting ? "结束多选并清除已勾选模块" : "进入多选模式，勾选需要单独发布的模块")
        .accessibilityLabel(isBatchSelecting ? "结束多选" : "进入多选")
        .accessibilityIdentifier("modules.toggle-batch-selection")
    }

    private var publishSelectedButton: some View {
        Button {
            let ids = batchSelectedModuleIDs
            Task {
                if await model.publishModules(moduleIDs: ids) {
                    batchSelectedModuleIDs.removeAll()
                    isBatchSelecting = false
                }
            }
        } label: {
            Label("发布所选", systemImage: "arrow.up.doc")
                .font(.system(size: 11, weight: .medium))
        }
        .disabled(
            model.isWorking ||
            batchSelectedModuleIDs.isEmpty ||
            !canPublishSelected
        )
        .help(publishSelectedHelp)
        .accessibilityIdentifier("modules.publish-selected")
    }

    private var canPublishSelected: Bool {
        model.settings.publishToLocal ||
        (model.settings.publishToGitHub && model.settings.github.isConfigured)
    }

    private var selectAllButton: some View {
        Button {
            batchSelectedModuleIDs = Set(model.modules.map(\.id))
        } label: {
            Label("全选", systemImage: "checkmark.square")
        }
        .disabled(model.isWorking || model.modules.isEmpty)
        .help("勾选全部模块")
        .accessibilityIdentifier("modules.select-all")
    }

    private var clearSelectionButton: some View {
        Button {
            batchSelectedModuleIDs.removeAll()
        } label: {
            Label("清空已选", systemImage: "xmark.square")
        }
        .disabled(model.isWorking || batchSelectedModuleIDs.isEmpty)
        .help("清空已勾选模块")
    }

    private var publishSelectedHelp: String {
        if batchSelectedModuleIDs.isEmpty { return "请选择要发布的模块" }
        if !model.settings.publishToLocal &&
            !(model.settings.publishToGitHub && model.settings.github.isConfigured) {
            return "请先在设置中开启本地发布或 GitHub 发布"
        }
        if model.settings.publishToGitHub,
           model.settings.github.isConfigured,
           !model.settings.publishToLocal,
           !model.modules.contains(where: { batchSelectedModuleIDs.contains($0.id) && $0.hasGitHubStorageTarget }) {
            return "当前勾选的是本地模块；请编辑模块并将“模块存放”改为 GitHub"
        }
        return "只发布勾选模块：本地模块写入本地目录，GitHub 模块推送到 GitHub，不删除其他已发布文件"
    }

    private var scanLocalModulesButton: some View {
        Button {
            scanLocalModules()
        } label: {
            Label("扫描本地模块…", systemImage: "folder.badge.plus")
        }
        .disabled(model.isWorking || isScanningLocalModules)
        .help("扫描本地目录的 Surge、Loon、Quantumult X 模块及带订阅来源的 Stash 覆写，并纳入管理")
    }

    private var publishAllHelp: String {
        if !model.settings.publishToGitHub { return "请在设置中开启 GitHub 发布" }
        if !model.settings.github.isConfigured { return "请先完成 GitHub 发布配置" }
        if !model.githubPublishPlan.hasPublishableModuleSelection {
            return "当前没有 GitHub 存放的可发布模块；请编辑模块并将“模块存放”改为 GitHub"
        }
        return "发布当前所有输出到 GitHub（⇧⌘P）"
    }

    private func publishAllAction() {
        guard model.settings.publishToGitHub, model.settings.github.isConfigured else {
            model.settingsPage = .publishing
            model.presentsSettings = true
            return
        }
        Task { await model.publishAll() }
    }
}
