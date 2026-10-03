import SwiftUI

enum SurgeRelayWindow {
    static let main = "main"
}

@main
struct SurgeRelayApp: App {
    @NSApplicationDelegateAdaptor(SurgeRelayAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var workspaces = WorkspaceController()

    var body: some Scene {
        let model = workspaces.activeModel
        Window("Surge Relay", id: SurgeRelayWindow.main) {
            RootView()
                .id(model.runtimeID)
                .environment(model)
                .environment(workspaces)
                .environment(\.moduleIconCacheDirectory, model.cacheDirectoryURL)
                .disabled(workspaces.isSwitching)
                .overlay {
                    if workspaces.isSwitching {
                        ProgressView("正在保存并切换工作区…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .task {
                    appDelegate.workspaces = workspaces
                    appDelegate.model = model
                    if !AppRuntimeOptions.isUIQAMode {
                        SparkleUpdateController.shared.start()
                    }
                    model.start()
                }
                .onDisappear { Task { await workspaces.finishViewRetirement(model) } }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active {
                        Task { try? await workspaces.flushAllWorkspaces() }
                    }
                }
                .frame(minWidth: 920, minHeight: 600)
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1240, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView()
                Button("查看 GitHub Release 资产…") {
                    model.presentsUpdateChecker = true
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { model.presentsSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("显示工作台") { model.selectedModuleID = AppModel.overviewSelectionID }
                    .keyboardShortcut("1", modifiers: .command)
                Button("显示活动记录") { model.selectedModuleID = AppModel.activitySelectionID }
                    .keyboardShortcut("2", modifiers: .command)
                Button("更新全部模块") {
                    model.startUpdateAll()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!model.updateAdmission.isAccepted)
            }
            // 模块文本编辑器的撤销/重做/查找命令。没有聚焦的编辑器时撤销与重做
            // 会转发回响应链，普通输入框的行为保持不变。
            CommandGroup(replacing: .undoRedo) {
                Button("撤销") { ModuleCodeEditorCommands.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                Button("重做") { ModuleCodeEditorCommands.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("查找…") { ModuleCodeEditorCommands.presentFind() }
                    .keyboardShortcut("f", modifiers: .command)
                Button("查找并替换…") { ModuleCodeEditorCommands.presentFind(showsReplace: true) }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Button("查找下一个") { ModuleCodeEditorCommands.find(forward: true) }
                    .keyboardShortcut("g", modifiers: .command)
                Button("查找上一个") { ModuleCodeEditorCommands.find(forward: false) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("跳转到行…") { ModuleCodeEditorCommands.presentGoToLine() }
                    .keyboardShortcut("l", modifiers: .command)
                Button("切换注释") { ModuleCodeEditorCommands.toggleComment() }
                    .keyboardShortcut("/", modifiers: .command)
            }
        }

        MenuBarExtra("Surge Relay", systemImage: "repeat") {
            MenuBarContent()
                .environment(model)
                .environment(workspaces)
                .environment(\.moduleIconCacheDirectory, model.cacheDirectoryURL)
                .disabled(workspaces.isSwitching)
        }
    }
}

@MainActor
final class SurgeRelayAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    weak var workspaces: WorkspaceController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NativeQAPerformanceRecorder.startAtApplicationLaunch()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task {
            var workspaceError: String?
            do {
                if let workspaces { try await workspaces.flushAllWorkspaces() }
                else {
                    await model.configurationMigrationTask?.value
                    await model.flushPreviewDrafts()
                    try await model.flushPersistence()
                }
            } catch { workspaceError = error.localizedDescription }
            let errors = [workspaceError, model.previewDraftPersistenceError, model.persistenceError].compactMap { $0 }
            if !errors.isEmpty {
                let alert = NSAlert()
                alert.messageText = "更改尚未保存"
                alert.informativeText = errors.joined(separator: "\n")
                alert.addButton(withTitle: "返回应用")
                alert.addButton(withTitle: "仍然退出")
                sender.reply(toApplicationShouldTerminate: alert.runModal() == .alertSecondButtonReturn)
            } else {
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}
