import SwiftUI

struct ModuleSidebarToolbarContent: ToolbarContent {
    @Environment(AppModel.self) private var model
    @Binding var isBatchSelecting: Bool
    @Binding var batchSelectedModuleIDs: Set<UUID>
    let isScanningLocalModules: Bool
    let addModule: () -> Void
    let scanLocalModules: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            addModuleButton
            updateAllButton
            publishAllButton
            batchSelectionButton
            if isBatchSelecting {
                selectAllButton
                clearSelectionButton
                publishSelectedButton
            }
            scanLocalModulesButton
        }
    }

    private var addModuleButton: some View {
        Button {
            addModule()
        } label: {
            Label("添加模块", systemImage: "plus")
        }
        .keyboardShortcut("n", modifiers: .command)
        .help("添加模块（⌘N）")
    }

    private var updateAllButton: some View {
        Button {
            model.startUpdateAll()
        } label: {
            Label("更新全部", systemImage: "arrow.clockwise")
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(!model.updateAdmission.isAccepted)
        .help(model.updateAdmission.isAccepted ? "更新全部模块（⌘R）" : model.updateAdmission.message)
    }

    private var publishAllButton: some View {
        Button {
            publishAllAction()
        } label: {
            Label("发布全部", systemImage: "square.and.arrow.up")
        }
        .keyboardShortcut("p", modifiers: [.command, .shift])
        .disabled(model.isWorking)
        .help(publishAllHelp)
        .accessibilityLabel("发布全部模块")
    }

    private var batchSelectionButton: some View {
        Button {
            isBatchSelecting.toggle()
            if !isBatchSelecting { batchSelectedModuleIDs.removeAll() }
        } label: {
            Label(isBatchSelecting ? "结束选择" : "多选", systemImage: isBatchSelecting ? "checkmark.circle" : "checklist")
        }
        .disabled(model.isWorking)
        .help(isBatchSelecting ? "结束多选并清除已勾选模块" : "进入多选模式，勾选需要单独发布的 GitHub 模块")
        .accessibilityLabel(isBatchSelecting ? "结束多选" : "进入多选")
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
            Label("发布所选", systemImage: "square.and.arrow.up.on.square")
        }
        .disabled(
            model.isWorking ||
            batchSelectedModuleIDs.isEmpty ||
            !canPublishSelected
        )
        .help(publishSelectedHelp)
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
        return "只发布勾选模块：本地模块写入本地目录，GitHub 模块推送到 GitHub，不删除其他已发布文件"
    }

    private var scanLocalModulesButton: some View {
        Button {
            scanLocalModules()
        } label: {
            Label("扫描本地模块", systemImage: "folder.badge.plus")
        }
        .disabled(model.isWorking || isScanningLocalModules)
        .help("扫描本地模块根目录下已有的 .sgmodule，并纳入 Surge Relay 管理")
    }

    private var publishAllHelp: String {
        if !model.settings.publishToGitHub { return "请在设置中开启 GitHub 发布" }
        if !model.settings.github.isConfigured { return "请先完成 GitHub 发布配置" }
        return "发布当前所有输出到 GitHub"
    }

    private func publishAllAction() {
        guard model.settings.publishToGitHub, model.settings.github.isConfigured else {
            model.presentsSettings = true
            return
        }
        Task { await model.publishAll() }
    }
}
