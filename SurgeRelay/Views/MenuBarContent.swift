import AppKit
import SwiftUI

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section("Surge Relay · \(model.workspaceName)") {
            if model.workActivity.isActive {
                Label(workingText, systemImage: "arrow.triangle.2.circlepath")
            }
            Label("上次同步：\(latestUpdateText)", systemImage: "clock")
            Label(moduleScopeText, systemImage: "square.stack.3d.up")
            if attentionCount > 0 {
                Label("需要处理：\(attentionCount) 项", systemImage: "exclamationmark.triangle.fill")
            }
        }

        Divider()

        Button("更新全部模块", systemImage: "arrow.clockwise") {
            model.startUpdateAll()
        }
        .disabled(!model.updateAdmission.isAccepted)

        if model.workActivity.isActive, model.workActivity.canCancel {
            Button(model.workCancellationRequested ? "正在取消…" : "取消当前任务", systemImage: "xmark.circle") {
                model.cancelCurrentWork()
            }
            .disabled(!model.canCancelCurrentWork)
        }

        Divider()

        Toggle("自动发布", isOn: Binding(
            get: { model.settings.automaticallyPublish },
            set: { model.settings.automaticallyPublish = $0; model.saveSettings() }
        ))
        Toggle("登录时启动", isOn: Binding(
            get: { model.settings.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        ))

        Divider()

        Button("打开工作台", systemImage: "square.grid.2x2") {
            model.selectedModuleID = AppModel.overviewSelectionID
            activateMainWindow()
        }
        Button("查看活动记录", systemImage: "clock.arrow.circlepath") {
            model.selectedModuleID = AppModel.activitySelectionID
            activateMainWindow()
        }
        Button("打开转换工具", systemImage: "arrow.left.arrow.right.square") {
            model.selectedModuleID = AppModel.conversionToolsSelectionID
            activateMainWindow()
        }

        Divider()

        CheckForUpdatesView()
        Button("查看 GitHub Release 资产…", systemImage: "shippingbox") {
            activateMainWindow()
            model.presentsUpdateChecker = true
        }
        Button("设置…", systemImage: "gearshape") {
            activateMainWindow()
            model.presentsSettings = true
        }

        Divider()

        Button("退出 Surge Relay") { NSApplication.shared.terminate(nil) }
    }

    private var latestUpdateText: String {
        guard let date = model.moduleSummary.latestUpdatedAt else { return "尚未更新" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var moduleScopeText: String {
        let summary = model.moduleSummary
        return "模块 \(summary.totalCount) · 本地 \(summary.localCount) · GitHub \(summary.githubCount)"
    }

    private var attentionCount: Int {
        model.moduleSummary.attentionCount
    }

    private var workingText: String {
        if model.workActivity.kind == .updatingModules, model.synchronizationTotalCount > 0 {
            return "正在更新 \(model.synchronizationCompletedCount) / \(model.synchronizationTotalCount)…"
        }
        let status = model.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !status.isEmpty, status != "准备就绪", status != model.workActivity.title else {
            return model.workActivity.title
        }
        return "\(model.workActivity.title)：\(status)"
    }

    private func activateMainWindow() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        openWindow(id: SurgeRelayWindow.main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSApp.activate(ignoringOtherApps: true)
            let window = NSApp.windows.first(where: {
                $0.canBecomeMain && $0.level == .normal && $0.title == "Surge Relay"
            }) ?? NSApp.windows.first(where: { $0.canBecomeMain && $0.level == .normal })
            window?.deminiaturize(nil)
            window?.makeKeyAndOrderFront(nil)
        }
    }
}
