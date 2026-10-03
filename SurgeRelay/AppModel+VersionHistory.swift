import Foundation

@MainActor
extension AppModel {
    func moduleVersions(moduleID: UUID) async throws -> [ModuleVersionRecord] {
        guard !isWorking else { throw PreviewContentSaveError.busy }
        guard modules.contains(where: { $0.id == moduleID }) else { throw RelayError.invalidOutput("模块已移除。") }
        beginWork(.previewingPublish)
        workActivity.title = "版本历史"
        defer { endWork(.previewingPublish) }
        do { _ = try await fileStore.recordCurrentVersion(id: moduleID, reason: .current) }
        catch { statusMessage = "当前缓存未能归档，仍可查看已有历史：\(error.localizedDescription)" }
        return try await fileStore.moduleVersions(id: moduleID)
    }

    func compareModuleVersion(moduleID: UUID, versionID: UUID) async throws -> ModuleVersionComparison {
        guard !isWorking else { throw PreviewContentSaveError.busy }
        guard let module = modules.first(where: { $0.id == moduleID }) else { throw RelayError.invalidOutput("模块已移除。") }
        beginWork(.previewingPublish)
        workActivity.title = "版本差异"
        defer { endWork(.previewingPublish) }
        let generation = localChangeGeneration
        let historical = try await fileStore.readModuleVersion(id: moduleID, versionID: versionID)
        let currentState = try await fileStore.currentVersionState(id: moduleID)
        let current = currentState.content
        let oldText = await previewContent(historical, for: module)
        let currentText: String
        if let current { currentText = await previewContent(current, for: module) }
        else { currentText = "" }
        let worker = Task.detached(priority: .userInitiated) {
            ModuleLineDiffPlanner.compare(local: oldText, github: currentText)
        }
        let diff = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard generation == localChangeGeneration, modules.first(where: { $0.id == moduleID }) == module else {
            throw RelayError.invalidOutput("模块在比较期间变化，请重新比较。")
        }
        let oldAssets = Dictionary(uniqueKeysWithValues: historical.record.assets.map { ($0.path, $0.contentHash) })
        let currentAssets = Dictionary(uniqueKeysWithValues: currentState.assets.map { ($0.path, $0.contentHash) })
        let changedAssets = Set(oldAssets.keys).union(currentAssets.keys).sorted().compactMap { path -> String? in
            guard oldAssets[path] != currentAssets[path] else { return nil }
            let prefix = oldAssets[path] == nil ? "+ " : currentAssets[path] == nil ? "− " : "~ "
            return prefix + path
        }
        return ModuleVersionComparison(module: module, version: historical.record,
                                       expectedFingerprint: currentState.fingerprint,
                                       diff: diff, changedAssets: changedAssets, currentContentProblem: currentState.problem)
    }

    func restoreModuleVersion(_ comparison: ModuleVersionComparison) async throws {
        guard !isWorking else { throw PreviewContentSaveError.busy }
        guard modules.first(where: { $0.id == comparison.module.id }) == comparison.module else {
            throw RelayError.invalidOutput("模块在比较后变化，请重新比较后回退。")
        }
        cancelAutomaticPublishSchedule()
        beginWork(.restoringPreview)
        workActivity.title = "恢复历史版本"
        defer { endWork(.restoringPreview) }
        registerLocalChange()
        let generation = localChangeGeneration
        let startedAt = Date.now
        let restored = try await fileStore.restoreModuleVersion(
            id: comparison.module.id, versionID: comparison.version.id, expectedFingerprint: comparison.expectedFingerprint
        )
        let fingerprint = await processingWorker.contentFingerprint(of: restored.content, assets: restored.assets)
        guard generation == localChangeGeneration, var module = modules.first(where: { $0.id == comparison.module.id }),
              module == comparison.module else {
            throw RelayError.invalidOutput("历史内容已写入缓存，但模块同时变化，请重新检查内容。")
        }
        module.contentHash = fingerprint
        module.overrideBaseHash = restored.record.hasOverride ? restored.convertedContent.map { Data($0.utf8).sha256String } : nil
        module.hasOverrideConflict = false
        module.refreshIntervalMinutes = 0
        module.lastUpdatedAt = .now
        module.sourceContentHash = nil
        module.sourceETag = nil
        module.sourceLastModified = nil
        module.sourceCheckedAt = nil
        module.conversionEngineRevision = nil
        module.state = .current
        module.lastError = nil
        replace(module)
        try persistModules()
        try await flushPersistence()
        guard await rebuildCombinedFromCache(schedulesAutomaticPublish: false, exportsLocalOutput: false) else {
            throw RelayError.invalidOutput("版本正文和脚本已恢复，但总模块缓存刷新失败。请检查错误后重新合并。")
        }
        recordHistory([UpdateHistoryEntry(moduleID: module.id, moduleName: module.name, outcome: .updated,
                                         duration: Date.now.timeIntervalSince(startedAt),
                                         message: "已恢复历史版本到缓存，本次未发布")])
        try await flushPersistence()
        try await fileStore.acknowledgeVersionRestoreMetadata(ids: [module.id])
        statusMessage = "已恢复历史正文和脚本，自动刷新已暂停；本次未发布，后续发布按现有设置执行，未保存草稿仍保留"
        if startupRecoveryFailed { Task { [weak self] in self?.start(performLaunchRefresh: false) } }
    }
}

@MainActor
extension AppModel {
    func recoverPersistedVersionState() async throws {
        let needsRebuild = try await fileStore.recoverInterruptedVersionRestores()
        let ids = try await fileStore.pendingVersionRestoreModuleIDs()
        guard needsRebuild || !ids.isEmpty else { return }
        for id in ids {
            guard var module = modules.first(where: { $0.id == id }) else { continue }
            let state = try await fileStore.currentVersionState(id: id)
            guard let current = state.content else {
                throw RelayError.invalidOutput(state.problem ?? "恢复后的模块正文缺失，请从版本历史恢复。")
            }
            module.contentHash = await processingWorker.contentFingerprint(of: current.content, assets: current.assets)
            module.overrideBaseHash = current.record.hasOverride ? current.convertedContent.map { Data($0.utf8).sha256String } : nil
            module.hasOverrideConflict = false
            module.sourceContentHash = nil
            module.sourceETag = nil
            module.sourceLastModified = nil
            module.sourceCheckedAt = nil
            module.conversionEngineRevision = nil
            module.refreshIntervalMinutes = 0
            module.lastUpdatedAt = .now
            module.state = .current
            module.lastError = nil
            replace(module)
        }
        try persistModulesIfNeeded(force: true)
        try await flushPersistence()
        guard await rebuildCombinedFromCache(schedulesAutomaticPublish: false, exportsLocalOutput: false) else {
            throw RelayError.invalidOutput("模块已恢复，但汇总缓存尚未重建；没有启动自动发布。")
        }
        try await fileStore.acknowledgeVersionRestoreMetadata(ids: ids)
    }
}
