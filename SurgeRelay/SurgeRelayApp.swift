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
                .task { model.start() }
                .frame(minWidth: 700)
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1240, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView {
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
        }

        MenuBarExtra("Surge Relay", systemImage: "repeat") {
            MenuBarContent()
                .environment(model)
        }
    }
}
