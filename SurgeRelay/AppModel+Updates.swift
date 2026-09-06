import Foundation

@MainActor
extension AppModel {
    func updateAll(only moduleIDs: Set<UUID>? = nil, refreshesScriptHubEngine: Bool = true) async {
        guard !Task.isCancelled else { return }
        let admission = updateAdmission
        guard admission.isAccepted else {
            statusMessage = admission.message
            return
        }
        let updateModules = ModuleRefreshPlanner.updateableModules(
            in: modules, combinedModuleEnabled: settings.combinedModuleEnabled
        ).filter { module in moduleIDs.map { $0.contains(module.id) } ?? true }
        if moduleIDs != nil, updateModules.isEmpty {
            statusMessage = "所选模块不可更新或没有可更新的来源"
            return
        }
        cancelAutomaticPublishSchedule()
        let generation = localChangeGeneration
        let originalModules = Dictionary(uniqueKeysWithValues: updateModules.map { ($0.id, $0) })
        var completedHistory: [UpdateHistoryEntry] = []
        beginWork(.updatingModules)
        synchronizationCompletedCount = 0
        synchronizationTotalCount = updateModules.count
        synchronizingModuleIDs = []
        defersModulePersistence = true
        defer {
            for index in modules.indices where modules[index].state == .updating {
                guard let original = originalModules[modules[index].id] else { continue }
                modules[index].state = ModuleUpdatePipeline.restoredState(for: original)
                modules[index].lastError = original.lastError
            }
            synchronizingModuleIDs = []
            moduleUpdateTask = nil
            updatePreparationTask = nil
            defersModulePersistence = false
            recordHistory(completedHistory)
            do { try persistModulesIfNeeded(force: true) }
            catch { presentedError = "保存更新结果失败：\(error.localizedDescription)" }
            endWork(.updatingModules)
        }
        let preparation = Task { @MainActor [self] in
            let needsConversion = updateModules.contains { module in
                guard let url = URL(string: module.updateSourceURL) else { return false }
                return !module.sourceFormat.isNativeSurgeModule(for: url)
            }
            let hasEngine = await engineStore.hasScript(named: "Rewrite-Parser.js")
            let missingEngine = needsConversion && !hasEngine
            if (refreshesScriptHubEngine && settings.automaticallyUpdateScriptHub && needsConversion) || missingEngine {
                await refreshScriptHubInternal()
            }
            guard shouldContinueCurrentWork(generation: generation) else { return }
            if settings.github.repositoryIsPrivate == nil, settings.github.isConfigured,
               githubTokenStorageStatus != .notChecked, !githubToken.isEmpty,
               let isPrivate = try? await githubClient.test(settings: settings.github, token: githubToken) {
                settings.github.repositoryIsPrivate = isPrivate
                saveSettings()
            }
        }
        updatePreparationTask = preparation
        await withTaskCancellationHandler { await preparation.value } onCancel: { preparation.cancel() }
        updatePreparationTask = nil
        guard shouldContinueCurrentWork(generation: generation) else { return }
        let task = Task { @MainActor [self] in
            await ModuleUpdatePipeline.run(updateModules) { [self] module in
                await updateSingleModule(module, generation: generation)
            } didComplete: { outcome in
                if outcome != nil { synchronizationCompletedCount += 1 }
            }
        }
        moduleUpdateTask = task
        let outcomes = await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }.compactMap { $0 }
        completedHistory = outcomes.flatMap(\.history).sorted { $0.date < $1.date }
        guard shouldContinueCurrentWork(generation: generation) else { return }
        await finishModuleUpdateRun(
            ModuleUpdateRunResult(
                components: outcomes.flatMap(\.components),
                failures: outcomes.reduce(0) { $0 + $1.failures },
                missingCacheModuleNames: outcomes.flatMap(\.missingCache),
                missingCacheDetails: outcomes.flatMap(\.missingCacheDetails),
                contentChanged: outcomes.contains(where: \.contentChanged)
            ),
            generation: generation,
            rebuildFromCache: moduleIDs != nil
        )
    }

    func update(moduleID: UUID) async {
        // 仅更新指定模块；若总模块开启，会从全部缓存组件重建总模块，避免丢失其他参与者。
        guard let module = modules.first(where: { $0.id == moduleID }) else { return }
        let admission = updateAdmission(for: module)
        guard admission.isAccepted else {
            statusMessage = admission.message
            return
        }
        await updateAll(only: [moduleID])
    }

}
