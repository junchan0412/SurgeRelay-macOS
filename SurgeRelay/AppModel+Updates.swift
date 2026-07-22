import Foundation

@MainActor
extension AppModel {
    func updateAll() async {
        let admission = updateAdmission
        guard admission.isAccepted else {
            statusMessage = admission.message
            return
        }
        let updateModules = ModuleRefreshPlanner.updateableModules(
            in: modules,
            combinedModuleEnabled: settings.combinedModuleEnabled
        )
        cancelAutomaticPublishSchedule()
        let updateGeneration = localChangeGeneration
        beginWork(.updatingModules)
        synchronizationCompletedCount = 0
        synchronizationTotalCount = updateModules.count
        synchronizingModuleID = nil
        defersModulePersistence = true
        defer {
            synchronizingModuleID = nil
            defersModulePersistence = false
            endWork(.updatingModules)
        }

        let missingEngine = !(await engineStore.hasScript(named: "Rewrite-Parser.js"))
        if settings.automaticallyUpdateScriptHub || missingEngine {
            await refreshScriptHubInternal()
        }
        guard shouldContinueCurrentWork(generation: updateGeneration) else { return }

        if settings.github.repositoryIsPrivate == nil,
           settings.github.isConfigured,
           githubTokenStorageStatus != .notChecked,
           !githubToken.isEmpty,
           let isPrivate = try? await githubClient.test(settings: settings.github, token: githubToken) {
            settings.github.repositoryIsPrivate = isPrivate
            saveSettings()
        }
        guard shouldContinueCurrentWork(generation: updateGeneration) else { return }

        var components: [(RelayModule, String)] = []
        var failures = 0
        var missingCache: [String] = []
        var missingCacheDetails: [String] = []
        var contentChanged = false
        var newHistory: [UpdateHistoryEntry] = []

        for moduleValue in updateModules {
            guard shouldContinueCurrentWork(generation: updateGeneration) else { return }
            var module = moduleValue
            let startedAt = Date.now
            var revisionSnapshot: SourceRevisionSnapshot?
            var sourceCheckFailure: (any Error)?
            synchronizingModuleID = module.id
            setState(id: module.id, state: .updating, error: nil)
            // Avoid rewriting identical high-frequency status strings for every module
            // when the UI already shows per-module progress.
            if synchronizationTotalCount <= 1 {
                statusMessage = "正在检查 \(module.name)…"
            } else if synchronizationCompletedCount == 0 {
                statusMessage = "正在更新 \(updateModules.count) 个模块…"
            }
            do {
                let hasCache = await fileStore.hasComponent(id: module.id)
                let sourceURL = URL(string: module.updateSourceURL)
                let nativeModule = sourceURL.map { module.sourceFormat.isNativeSurgeModule(for: $0) } ?? false
                let engineChanged = !nativeModule && module.conversionEngineRevision != upstreamState.revision
                if hasCache {
                    do {
                        let revision = try await sourceRevisionService.check(module)
                        switch revision {
                        case let .unchanged(snapshot):
                            revisionSnapshot = snapshot
                            if !engineChanged {
                                let metadataPlan = ModuleMetadataRefreshPlanner.unchangedCachedContentPlan(
                                    module: module,
                                    revisionSnapshot: snapshot
                                )
                                module = metadataPlan.module
                                replace(module)
                                let cached = try await fileStore.readComponent(id: module.id)
                                let materialized = await processingWorker.materialize(cached, overrides: module.argumentOverrides)
                                if shouldContributeToCombined(module) {
                                    components.append((module, materialized))
                                }
                                newHistory.append(UpdateHistoryEntry(
                                    moduleID: module.id,
                                    moduleName: module.name,
                                    outcome: .unchanged,
                                    duration: Date.now.timeIntervalSince(startedAt),
                                    message: metadataPlan.historyMessage
                                ))
                                synchronizationCompletedCount += 1
                                await Task.yield()
                                continue
                            }
                        case let .changed(snapshot):
                            revisionSnapshot = snapshot
                        }
                    } catch {
                        sourceCheckFailure = error
                        // A failed lightweight check must not prevent the normal conversion path.
                    }
                }
                guard shouldContinueCurrentWork(generation: updateGeneration) else { return }
                if synchronizationTotalCount <= 1 {
                    statusMessage = "正在内置转换 \(module.name)…"
                }
                let result = try await scriptHubClient.convert(
                    module: module,
                    github: settings.github.isConfigured ? settings.github : nil
                )
                guard shouldContinueCurrentWork(generation: updateGeneration) else { return }
                guard let currentIndex = modules.firstIndex(where: { $0.id == module.id }),
                      shouldUpdateModule(modules[currentIndex]) else {
                    statusMessage = "检测到新的修改，已放弃旧更新"
                    return
                }
                try await fileStore.replaceAssets(result.assets, id: module.id)
                try await fileStore.writeComponent(result.content, id: module.id)
                let effectiveContent = try await fileStore.readComponent(id: module.id)
                guard shouldContinueCurrentWork(generation: updateGeneration) else { return }
                guard let latestIndex = modules.firstIndex(where: { $0.id == module.id }),
                      shouldUpdateModule(modules[latestIndex]) else {
                    statusMessage = "检测到新的修改，已放弃旧更新"
                    return
                }
                module = modules[latestIndex]
                let convertedContent = try await fileStore.readConvertedComponent(id: module.id)
                let detectedIcon = await processingWorker.iconURL(
                    in: effectiveContent,
                    relativeTo: module.updateSourceURL
                )
                let nextContentHash = await processingWorker.contentFingerprint(
                    of: effectiveContent,
                    assets: result.assets
                )
                let metadataPlan = await ModuleMetadataRefreshPlanner.successfulConversionPlan(
                    module: module,
                    revisionSnapshot: revisionSnapshot,
                    nativeModule: nativeModule,
                    engineRevision: upstreamState.revision,
                    convertedContent: convertedContent,
                    effectiveContent: effectiveContent,
                    hasOverride: fileStore.hasOverride(id: module.id),
                    detectedIconURL: detectedIcon,
                    nextContentHash: nextContentHash
                )
                module = metadataPlan.module
                if let preferredIcon = metadataPlan.preferredIconURL {
                    try? await iconStore.cacheIcon(
                        from: preferredIcon,
                        for: module.id,
                        force: metadataPlan.shouldRefreshIconCache
                    )
                } else {
                    try? await iconStore.removeIcon(for: module.id)
                }
                if metadataPlan.contentChanged { contentChanged = true }
                replace(module)
                newHistory.append(UpdateHistoryEntry(
                    moduleID: module.id,
                    moduleName: module.name,
                    outcome: .updated,
                    duration: Date.now.timeIntervalSince(startedAt),
                    message: metadataPlan.historyMessage,
                    contentChanged: metadataPlan.contentChanged
                ))
                let materialized = await processingWorker.materialize(
                    effectiveContent,
                    overrides: module.argumentOverrides
                )
                if shouldContributeToCombined(module) {
                    components.append((module, materialized))
                }
            } catch {
                guard shouldContinueCurrentWork(generation: updateGeneration) else { return }
                failures += 1
                let sourceFailure = await sourceCheckFailureAfterConversionFailure(
                    error,
                    module: module,
                    existingFailure: sourceCheckFailure
                )
                let failureMessage = UpdateFailurePlanner.detailedMessage(
                    for: error,
                    module: module,
                    latestModule: modules.first(where: { $0.id == module.id }),
                    sourceCheckFailure: sourceFailure
                )
                setState(id: module.id, state: .failed, error: failureMessage)
                if let cached = try? await fileStore.readComponent(id: module.id) {
                    let current = modules.first(where: { $0.id == module.id }) ?? module
                    let materialized = await processingWorker.materialize(
                        cached,
                        overrides: current.argumentOverrides
                    )
                    let failurePlan = UpdateFailurePlanner.cachedFailureOutcome(
                        module: module,
                        failureMessage: failureMessage,
                        duration: Date.now.timeIntervalSince(startedAt),
                        contributesToCombined: shouldContributeToCombined(current)
                    )
                    if failurePlan.shouldUseCachedContentInCombined {
                        components.append((current, materialized))
                    }
                    newHistory.append(failurePlan.historyEntry)
                } else {
                    let failurePlan = UpdateFailurePlanner.missingCacheFailureOutcome(
                        module: module,
                        failureMessage: failureMessage,
                        duration: Date.now.timeIntervalSince(startedAt),
                        contributesToCombined: shouldContributeToCombined(module)
                    )
                    if let moduleName = failurePlan.missingCacheModuleName {
                        missingCache.append(moduleName)
                    }
                    if let detail = failurePlan.missingCacheDetail {
                        missingCacheDetails.append(detail)
                    }
                    newHistory.append(failurePlan.historyEntry)
                }
            }
            synchronizationCompletedCount += 1
            await Task.yield()
        }
        recordHistory(newHistory)
        defersModulePersistence = false
        try? persistModulesIfNeeded(force: true)

        guard shouldContinueCurrentWork(generation: updateGeneration) else { return }

        await finishModuleUpdateRun(
            ModuleUpdateRunResult(
                components: components,
                failures: failures,
                missingCacheModuleNames: missingCache,
                missingCacheDetails: missingCacheDetails,
                contentChanged: contentChanged
            ),
            generation: updateGeneration
        )
    }

    func update(moduleID: UUID) async {
        // 单个来源改变可能影响总模块，也可能触发独立模块输出，因此统一走批量更新路径。
        guard let module = modules.first(where: { $0.id == moduleID }) else { return }
        let admission = updateAdmission(for: module)
        guard admission.isAccepted else {
            statusMessage = admission.message
            return
        }
        await updateAll()
    }

    private func sourceCheckFailureAfterConversionFailure(
        _ error: any Error,
        module: RelayModule,
        existingFailure: (any Error)?
    ) async -> (any Error)? {
        if let existingFailure { return existingFailure }
        guard UpdateFailurePlanner.shouldCheckUpdateSourceAfterConversionFailure(
            error,
            module: module,
            existingSourceCheckFailure: existingFailure
        ) else {
            return nil
        }

        do {
            _ = try await sourceRevisionService.check(module)
            return nil
        } catch {
            return error
        }
    }
}
