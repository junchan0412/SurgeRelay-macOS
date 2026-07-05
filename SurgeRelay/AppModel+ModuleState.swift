import Foundation

@MainActor
extension AppModel {
    func shouldContributeToCombined(_ module: RelayModule) -> Bool {
        ModuleRefreshPlanner.contributesToCombined(
            module,
            combinedModuleEnabled: settings.combinedModuleEnabled
        )
    }

    func shouldUpdateModule(_ module: RelayModule) -> Bool {
        ModuleRefreshPlanner.isUpdateable(
            module,
            combinedModuleEnabled: settings.combinedModuleEnabled
        )
    }

    var updateAdmission: UpdateAdmission {
        UpdateAdmission.allModules(
            activity: workActivity,
            updateableModuleCount: updateableModuleCount,
            statusMessage: statusMessage
        )
    }

    func updateAdmission(for module: RelayModule) -> UpdateAdmission {
        UpdateAdmission.module(
            module,
            moduleIsUpdateable: shouldUpdateModule(module),
            activity: workActivity,
            updateableModuleCount: updateableModuleCount,
            statusMessage: statusMessage
        )
    }

    var moduleSummary: ModuleCollectionSummary {
        ModuleCollectionSummary(modules: modules, isUpdateable: shouldUpdateModule)
    }

    var updateableModuleCount: Int {
        moduleSummary.updateableCount
    }

    var canCancelCurrentWork: Bool {
        workActivity.isActive && workActivity.canCancel && !workCancellationRequested
    }
}
