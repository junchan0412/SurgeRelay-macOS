import Foundation

enum ModuleRefreshPlanner {
    static func contributesToCombined(
        _ module: RelayModule,
        combinedModuleEnabled: Bool
    ) -> Bool {
        combinedModuleEnabled && module.isEnabled
    }

    static func combinedContributorModules(
        in modules: [RelayModule],
        combinedModuleEnabled: Bool
    ) -> [RelayModule] {
        modules.filter {
            contributesToCombined($0, combinedModuleEnabled: combinedModuleEnabled)
        }
    }

    static func isUpdateable(
        _ module: RelayModule,
        combinedModuleEnabled: Bool
    ) -> Bool {
        module.hasRemoteUpdateSource ||
            contributesToCombined(module, combinedModuleEnabled: combinedModuleEnabled) ||
            module.publishesStandalone
    }

    static func updateableModules(
        in modules: [RelayModule],
        combinedModuleEnabled: Bool
    ) -> [RelayModule] {
        modules.filter {
            isUpdateable($0, combinedModuleEnabled: combinedModuleEnabled)
        }
    }

    static func shouldUpdateOnLaunch(
        modules: [RelayModule],
        combinedModuleEnabled: Bool,
        refreshIntervalMinutes: Int,
        now: Date = .now,
        componentExists: @Sendable (UUID) async -> Bool
    ) async -> Bool {
        let updateModules = updateableModules(
            in: modules,
            combinedModuleEnabled: combinedModuleEnabled
        )
        guard !updateModules.isEmpty else { return false }

        for module in updateModules {
            if module.lastUpdatedAt == nil { return true }
            if !(await componentExists(module.id)) { return true }
        }

        let oldestUpdate = updateModules.compactMap(\.lastUpdatedAt).min()
        return RefreshPolicy.isDue(
            lastUpdatedAt: oldestUpdate,
            intervalMinutes: refreshIntervalMinutes,
            now: now
        )
    }
}
