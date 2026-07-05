import Foundation

@MainActor
extension AppModel {
    func savePreviewContent(_ content: String, for module: RelayModule) async throws {
        guard !isWorking else { throw RelayError.invalidOutput("当前正在更新，请稍后再写入。") }
        let namedContent = await processingWorker.applyingModuleMetadata(
            name: module.name,
            category: module.category,
            to: content
        )
        let currentContent = try? await modulePreviewProvider.componentContent(for: module)
        if currentContent == namedContent {
            let plan = ModulePreviewEditPlanner.savePlan(
                module: module,
                namedContent: namedContent,
                currentContent: currentContent,
                convertedContent: nil,
                automaticallyPublish: settings.automaticallyPublish
            )
            statusMessage = plan.statusMessage
            return
        }
        beginWork(.savingPreview)
        defer { endWork(.savingPreview) }
        registerLocalChange()
        let convertedContent = try? await modulePreviewProvider.convertedComponentContent(for: module)
        let moduleForPlan = modules.first(where: { $0.id == module.id }) ?? module
        let plan = ModulePreviewEditPlanner.savePlan(
            module: moduleForPlan,
            namedContent: namedContent,
            currentContent: currentContent,
            convertedContent: convertedContent,
            automaticallyPublish: settings.automaticallyPublish
        )
        try await fileStore.writeComponentOverride(plan.overrideContent, id: module.id)
        if let index = modules.firstIndex(where: { $0.id == module.id }) {
            modules[index] = plan.module
        }
        await rebuildCombinedFromCache()
        try persistModules()
        statusMessage = plan.statusMessage
    }

    func restorePreviewContent(for module: RelayModule) async throws -> String {
        guard !isWorking else { throw RelayError.invalidOutput("当前正在更新，请稍后再恢复。") }
        beginWork(.restoringPreview)
        defer { endWork(.restoringPreview) }
        registerLocalChange()
        try await fileStore.removeComponentOverride(id: module.id)
        let content = try await modulePreviewProvider.convertedComponentContent(for: module)
        let moduleForPlan = modules.first(where: { $0.id == module.id }) ?? module
        let plan = ModulePreviewEditPlanner.restorePlan(
            module: moduleForPlan,
            automaticallyPublish: settings.automaticallyPublish
        )
        if let index = modules.firstIndex(where: { $0.id == module.id }) {
            modules[index] = plan.module
            try? persistModules()
        }
        await rebuildCombinedFromCache()
        statusMessage = plan.statusMessage
        let materialized = await processingWorker.materialize(content, overrides: module.argumentOverrides)
        return await processingWorker.applyingModuleMetadata(
            name: module.name,
            category: module.category,
            to: materialized
        )
    }

    func acceptOverrideConflict(moduleID: UUID) async {
        guard let index = modules.firstIndex(where: { $0.id == moduleID }),
              let converted = try? await modulePreviewProvider.convertedComponentContent(for: modules[index]) else { return }
        let plan = ModulePreviewEditPlanner.acceptConflictPlan(
            module: modules[index],
            convertedContent: converted
        )
        modules[index] = plan.module
        try? persistModules()
        statusMessage = plan.statusMessage
    }
}
