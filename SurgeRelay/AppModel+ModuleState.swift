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
        if let cachedModuleSummary, cachedModuleSummaryToken == moduleSummaryToken {
            return cachedModuleSummary
        }
        let summary = ModuleCollectionSummary(modules: modules, isUpdateable: shouldUpdateModule)
        cachedModuleSummary = summary
        cachedModuleSummaryToken = moduleSummaryToken
        return summary
    }

    var updateableModuleCount: Int {
        moduleSummary.updateableCount
    }

    var canCancelCurrentWork: Bool {
        workActivity.isActive && workActivity.canCancel && !workCancellationRequested
    }

    /// Signature of the fields that affect ModuleCollectionSummary.
    var moduleSummaryToken: String {
        modules.map { module in
            [
                module.id.uuidString,
                module.isEnabled ? "1" : "0",
                module.publishesStandalone ? "1" : "0",
                module.state.rawValue,
                module.hasOverrideConflict ? "1" : "0",
                module.lastUpdatedAt.map { String($0.timeIntervalSinceReferenceDate) } ?? "",
                // updateable depends on source validity / combined participation
                shouldUpdateModule(module) ? "1" : "0",
            ].joined(separator: ":")
        }.joined(separator: "|") + "|\(settings.combinedModuleEnabled ? 1 : 0)"
    }

    func invalidateModuleSummaryCache() {
        cachedModuleSummary = nil
        cachedModuleSummaryToken = nil
    }
}
