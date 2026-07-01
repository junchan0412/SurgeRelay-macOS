import Sparkle
import SwiftUI

enum SurgeRelayWindow {
    static let main = "main"
}

@main
struct SurgeRelayApp: App {
    @State private var model = AppModel()
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

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
                CheckForUpdatesView(updater: updaterController.updater)
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { model.presentsSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("更新全部模块") {
                    Task { await model.updateAll() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.isWorking)
            }
        }

        MenuBarExtra("Surge Relay", systemImage: "repeat") {
            MenuBarContent(updater: updaterController.updater)
                .environment(model)
        }
    }
}
