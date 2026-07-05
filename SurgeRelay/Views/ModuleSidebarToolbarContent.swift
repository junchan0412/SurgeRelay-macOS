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
    }

    private var updateAllButton: some View {
        Button {
            model.startUpdateAll()
        } label: {
            Label("更新全部", systemImage: "arrow.clockwise")
        }
        .disabled(!model.updateAdmission.isAccepted)
        .help(model.updateAdmission.isAccepted ? "更新全部模块" : model.updateAdmission.message)
    }

    private var publishAllButton: some View {
        Button {
            Task { await model.publishAll() }
        } label: {
            Label("发布全部", systemImage: "square.and.arrow.up")
        }
        .disabled(model.isWorking || !model.settings.publishToGitHub || !model.settings.github.isConfigured)
        .help(model.settings.publishToGitHub ? "发布当前所有输出到 GitHub" : "未开启 GitHub 发布")
    }

    private var batchSelectionButton: some View {
        Button {
            isBatchSelecting.toggle()
            if !isBatchSelecting { batchSelectedModuleIDs.removeAll() }
        } label: {
            Label(isBatchSelecting ? "结束选择" : "多选", systemImage: isBatchSelecting ? "checkmark.circle" : "checklist")
        }
        .disabled(model.isWorking)
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
            !model.settings.publishToGitHub ||
            !model.settings.github.isConfigured
        )
        .help(batchSelectedModuleIDs.isEmpty ? "请选择要发布的模块" : "只发布勾选模块，不删除其他已发布文件")
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
}
