import SwiftUI

enum SurgeRelayWindow {
    static let main = "main"
}

@main
struct SurgeRelayApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Surge Relay", id: SurgeRelayWindow.main) {
            RootView()
                .environment(model)
                .task {
                    if !AppRuntimeOptions.isUIQAMode {
                        SparkleUpdateController.shared.start()
                    }
                    model.start()
                }
                .frame(minWidth: 700)
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
        }
    }
}
