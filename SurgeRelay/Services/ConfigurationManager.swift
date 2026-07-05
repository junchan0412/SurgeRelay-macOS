import Foundation

enum ConfigurationManager {
    static var configurationDirectoryPath: String {
        PersistenceStore.configurationDirectoryURL.path
    }

    static func migrateConfiguration(
        to path: String,
        modules: [RelayModule],
        settings: AppSettings,
        upstreamState: ScriptHubUpstreamState,
        updateHistory: [UpdateHistoryEntry]
    ) throws {
        try PersistenceStore.useConfigurationDirectory(path)
        try PersistenceStore.saveModules(modules)
        PersistenceStore.saveSettings(settings)
        PersistenceStore.saveUpstreamState(upstreamState)
        PersistenceStore.saveUpdateHistory(updateHistory)
    }
}
